import Foundation
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "QueryServer")

/// Request: which screen (by frame) is the caller asking about.
struct WorkspaceWindowsQuery: Decodable {
    let screenFrame: FlatRect
}

/// Response: the exact window IDs on the workspace shown on that screen.
struct WorkspaceWindowsResponse: Encodable {
    let windowIds: [UInt32]
}

/// Brain replies to ignored-window attribution queries. A waiting query is
/// matched by the echoed screen frame: the first reply for its frame goes to
/// the first waiter for that frame. Replies nobody waits for are dropped.
final class IgnoredAttributionWaiters: @unchecked Sendable {
    static let shared = IgnoredAttributionWaiters()

    private final class Waiter {
        let frame: CGRect
        let semaphore = DispatchSemaphore(value: 0)
        var windowIds: [UInt32]?

        init(frame: CGRect) { self.frame = frame }
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []

    /// Registers a waiter for `frame`, runs `send` to ask the brain, then
    /// waits up to `timeout`. Returns the brain's ids, or nil on timeout.
    func query(frame: CGRect, timeout: DispatchTimeInterval, send: () -> Void) -> [UInt32]? {
        let waiter = Waiter(frame: frame)
        lock.lock()
        waiters.append(waiter)
        lock.unlock()

        send()
        _ = waiter.semaphore.wait(timeout: .now() + timeout)

        lock.lock()
        defer { lock.unlock() }
        waiters.removeAll { $0 === waiter }
        return waiter.windowIds
    }

    func deliver(screenFrame: CGRect, windowIds: [UInt32]) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = waiters.firstIndex(where: {
            $0.windowIds == nil && sameFrame($0.frame, screenFrame)
        }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.windowIds = windowIds
        waiter.semaphore.signal()
    }

    /// Frames from the same screen can differ by float noise after a JSON
    /// round trip; anything within half a point counts as the same.
    private func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

/// One-shot, read-only queries against the latest cached `OverlaySnapshot` —
/// e.g. "which windows are on the workspace currently shown on this screen".
/// Unlike `SocketServer` (the persistent brain<->core channel, deliberately
/// single-client), each connection here is a single request/response that
/// then closes, so many independent short-lived clients can be served
/// without contending with each other.
final class QueryServer {
    let path: String
    private let snapshotBox: SnapshotBox
    private let socketServer: SocketServer

    init(snapshotBox: SnapshotBox, socketServer: SocketServer, path: String? = nil) {
        self.snapshotBox = snapshotBox
        self.socketServer = socketServer
        let configDir = NSHomeDirectory() + "/.config/mcmonad"
        self.path = path ?? (configDir + "/query.sock")
    }

    func start() {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create socket directory \(dir): \(error)")
            return
        }

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("Failed to create query socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathCopy = path
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                _ = strncpy(buf, pathCopy, 103)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            logger.error("Failed to bind query socket at \(self.path): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Backlog > 1: connections here are short-lived (one request, one
        // response, close), so a few can queue briefly without blocking.
        guard listen(fd, 8) == 0 else {
            logger.error("Failed to listen on query socket: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        logger.info("Query server listening at \(self.path)")

        let box = snapshotBox
        let server = socketServer
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else {
                    if errno == EINTR { continue }
                    logger.error("Query accept failed: \(String(cString: strerror(errno)))")
                    return
                }
                // Each client is handled on its own task so a slow or stuck
                // one can't block others from connecting.
                DispatchQueue.global(qos: .userInitiated).async {
                    QueryServer.handleClient(clientFd, snapshotBox: box, socketServer: server)
                }
            }
        }
    }

    private static func handleClient(_ clientFd: Int32, snapshotBox: SnapshotBox, socketServer: SocketServer) {
        let handle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: true)
        defer { try? handle.close() }

        var buffer = Data()
        let newline = UInt8(0x0A)

        while true {
            var pollFd = pollfd(fd: clientFd, events: Int16(POLLIN), revents: 0)
            // 1s timeout — a slow or misbehaving client shouldn't hold a
            // thread forever.
            let ret = poll(&pollFd, 1, 1000)
            if ret <= 0 { return }
            if pollFd.revents & Int16(POLLHUP) != 0 || pollFd.revents & Int16(POLLERR) != 0 { return }

            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(clientFd, &buf, buf.count)
            if n <= 0 { return }
            buffer.append(contentsOf: buf[0..<n])

            guard let newlineIndex = buffer.firstIndex(of: newline) else { continue }
            let lineData = Data(buffer[buffer.startIndex..<newlineIndex])
            guard let request = try? JSONDecoder().decode(WorkspaceWindowsQuery.self, from: lineData) else {
                return
            }

            let windowIds = windowIds(
                forScreenFrame: request.screenFrame.cgRect,
                in: snapshotBox.get(),
                socketServer: socketServer
            )
            guard var payload = try? JSONEncoder().encode(WorkspaceWindowsResponse(windowIds: windowIds)) else {
                return
            }
            payload.append(newline)
            try? handle.write(contentsOf: payload)
            return
        }
    }

    private static func windowIds(
        forScreenFrame target: CGRect, in snapshot: OverlaySnapshot?, socketServer: SocketServer
    ) -> [UInt32] {
        WorkspaceWindowLookup.windowIds(forScreenFrame: target, in: snapshot) {
            attributedIgnoredWindowIds(in: $0, forScreenFrame: target, socketServer: socketServer)
        }
    }

    /// Ignored windows (doIgnore) carry no frame or workspace tag, so their
    /// screen is resolved on every query. Core only reads their live AX
    /// frames; the brain, which owns screen geometry, decides which screen
    /// each one belongs to. If the brain doesn't answer in time, the ignored
    /// windows are left out of this screen's list.
    private static func attributedIgnoredWindowIds(
        in snapshot: OverlaySnapshot, forScreenFrame frame: CGRect, socketServer: SocketServer
    ) -> [UInt32] {
        guard !snapshot.ignoredWindows.isEmpty else { return [] }
        var facts: [IgnoredAttributionFact] = []
        for ignored in snapshot.ignoredWindows {
            guard let live = AXWindowService.readFrame(windowId: ignored.windowId, pid: ignored.pid) else {
                logger.debug("IGNORED-QUERY: window \(ignored.windowId) pid \(ignored.pid) has no live AX frame, skipping")
                continue
            }
            facts.append(IgnoredAttributionFact(windowId: ignored.windowId, pid: ignored.pid, frame: FlatRect(live)))
        }
        let reply = IgnoredAttributionWaiters.shared.query(frame: frame, timeout: .milliseconds(250)) {
            let event = IPCEvent.ignoredAttributionQuery(screenFrame: frame, windows: facts)
            Task { @MainActor in socketServer.send(event) }
        }
        guard let reply else {
            logger.error("IGNORED-QUERY: no brain reply within 250ms for screen \(frame.debugDescription); omitting ignored windows")
            return []
        }
        return reply
    }
}
