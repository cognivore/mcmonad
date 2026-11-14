import Foundation
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "SocketServer")

@MainActor
final class SocketServer {
    let path: String
    var onCommand: (@MainActor (IPCCommand) -> Void)?
    var onClientConnected: (@MainActor () -> Void)?

    private let encoder = JSONEncoder()

    /// Shared mutable state protected by a lock, accessed from both main and background threads.
    private let state = SocketState()

    init(path: String? = nil) {
        let configDir = NSHomeDirectory() + "/.config/mcmonad"
        self.path = path ?? (configDir + "/core.sock")
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

        // Remove stale socket
        unlink(path)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("Failed to create socket: \(String(cString: strerror(errno)))")
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
            logger.error("Failed to bind socket at \(self.path): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard listen(fd, 1) == 0 else {
            logger.error("Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        logger.info("Socket server listening at \(self.path)")

        let sharedState = self.state
        let decoder = JSONDecoder()

        // Accept loop runs on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else {
                    if errno == EINTR { continue }
                    logger.error("Accept failed: \(String(cString: strerror(errno)))")
                    return
                }
                logger.info("Client connected")
                // A brain that stops reading must not stop the daemon:
                // writes happen on the main thread. Give each write a
                // deadline; a brain that misses it is disconnected (see
                // `SocketState.writeData`).
                var deadline = timeval(tv_sec: SocketServer.writeTimeoutSeconds, tv_usec: 0)
                setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
                let handle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: true)

                sharedState.setClientHandle(handle)

                Task { @MainActor [weak self] in
                    self?.onClientConnected?()
                }

                // Read loop (blocking, runs on this background thread)
                SocketServer.readLoop(
                    handle: handle,
                    decoder: decoder,
                    onCommand: { [weak self] command in
                        Task { @MainActor in
                            self?.onCommand?(command)
                        }
                    }
                )

                sharedState.setClientHandle(nil)
                logger.info("Client disconnected, waiting for reconnection")
            }
        }
    }

    func send(_ event: IPCEvent) {
        do {
            let data = try encoder.encode(event)
            sendLine(data)
        } catch {
            logger.error("Failed to encode event: \(error)")
        }
    }

    func sendRaw(_ data: Data) {
        sendLine(data)
    }

    // MARK: - Private

    private func sendLine(_ data: Data) {
        var payload = data
        payload.append(0x0A) // newline
        state.writeData(payload)
    }

    /// How long one write to the brain may block before the brain is
    /// treated as wedged and disconnected.
    nonisolated static let writeTimeoutSeconds = 2

    /// The longest command line accepted from the brain. The largest real
    /// command is an overlay snapshot of every window; this is orders of
    /// magnitude above that and exists so a peer that never sends a
    /// newline cannot grow the buffer without limit.
    nonisolated static let maxLineBytes = 8 * 1024 * 1024

    /// Read loop runs entirely on a background thread — no @MainActor references.
    private nonisolated static func readLoop(
        handle: FileHandle,
        decoder: JSONDecoder,
        onCommand: @escaping @Sendable (IPCCommand) -> Void
    ) {
        var buffer = Data()
        let newline = UInt8(0x0A)
        let fd = handle.fileDescriptor

        while true {
            var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ret = poll(&pollFd, 1, -1)
            if ret < 0 {
                if errno == EINTR { continue }
                logger.warning("Poll error: \(String(cString: strerror(errno)))")
                break
            }
            if pollFd.revents & Int16(POLLHUP) != 0
                || pollFd.revents & Int16(POLLERR) != 0
            {
                break
            }

            var buf = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 {
                logger.warning("Read error: \(String(cString: strerror(errno)))")
                break
            }
            if n == 0 { break } // EOF

            buffer.append(contentsOf: buf[0..<n])

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = Data(buffer[buffer.startIndex..<newlineIndex])
                buffer.removeSubrange(buffer.startIndex...newlineIndex)

                guard !lineData.isEmpty else { continue }

                do {
                    let command = try decoder.decode(IPCCommand.self, from: lineData)
                    onCommand(command)
                } catch {
                    // Commands include overlay snapshots with raw window
                    // titles; decoder descriptions can quote them as well.
                    logger.error("Failed to decode command (\(lineData.count) bytes; payload and parser details withheld for privacy)")
                }
            }
            if buffer.count > maxLineBytes {
                logger.error("Command line exceeds \(maxLineBytes) bytes without a newline; disconnecting the client")
                break
            }
        }
    }
}

// MARK: - Thread-safe socket state

/// Lock-protected client handle for cross-thread read/write safety.
private final class SocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var clientHandle: FileHandle?

    func setClientHandle(_ handle: FileHandle?) {
        lock.lock()
        clientHandle = handle
        lock.unlock()
    }

    /// Write one line to the brain. A write that fails or misses the
    /// socket's send deadline means the brain is gone or wedged; what it
    /// missed cannot be replayed, so the connection is shut down. The read
    /// loop then ends, the brain sees end-of-file when it next looks, and
    /// its restart resynchronises from a fresh enumeration.
    func writeData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = clientHandle else { return }
        let fd = handle.fileDescriptor
        let failure: String? = data.withUnsafeBytes { raw -> String? in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                return String(cString: strerror(errno))
            }
            return nil
        }
        if let failure {
            logger.warning("Write to client failed (\(failure)); disconnecting it")
            clientHandle = nil
            shutdown(fd, SHUT_RDWR)
        }
    }
}
