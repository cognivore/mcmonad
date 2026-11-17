import Foundation

// AI-generated text: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).

/// One line `awake --json` prints: protocol 1, `awake_core::Report` in
/// awake/core. awake decides everything; mcmonad shows these words.
struct AwakeReport: Decodable, Equatable, Sendable {
    enum Phase: String, Decodable, Sendable {
        /// Keeping the Mac awake; `line` says for how long and on what charge.
        case running
        /// Over; `line` says why and whether the Mac goes to sleep.
        case ended
        /// Never started: the request or the Mac's state did not allow it.
        case refused
        /// Never started: something it needed failed, such as the lock.
        case failed
    }

    /// Another process keeping the Mac or its display awake.
    struct Holder: Decodable, Equatable, Sendable {
        let pid: Int32
        let process: String
        let what: String
    }

    let awake: Int
    let phase: Phase
    let line: String
    let warning: String?
    let holders: [Holder]
}

/// Why a line from `awake` was not a report this mcmonad can show.
enum AwakeDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    case version(Int)
    case malformed(String)

    var description: String {
        switch self {
        case .version(let v): return "protocol \(v), not \(AwakeProtocol.version)"
        case .malformed(let why): return why
        }
    }
}

enum AwakeProtocol {
    static let version = 1

    /// A report of exactly this protocol version, or why not.
    static func decode(_ line: Data) -> Result<AwakeReport, AwakeDecodeError> {
        struct Tag: Decodable { let awake: Int }
        let decoder = JSONDecoder()
        guard let tag = try? decoder.decode(Tag.self, from: line) else {
            return .failure(.malformed("not a line of awake's protocol"))
        }
        guard tag.awake == version else { return .failure(.version(tag.awake)) }
        do {
            return .success(try decoder.decode(AwakeReport.self, from: line))
        } catch {
            return .failure(.malformed("a protocol-1 line that does not decode: \(error)"))
        }
    }

    /// Complete lines out of `buffer`, leaving any unfinished one in it.
    static func takeLines(_ buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return lines
    }
}
