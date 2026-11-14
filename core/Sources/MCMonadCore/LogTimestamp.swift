import Foundation

/// Millisecond timestamp prefix for stderr log lines, so lines can be
/// correlated with how much time actually passed between them, not just
/// their relative order.
private let logTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func logTS() -> String {
    logTimestampFormatter.string(from: Date()) + " "
}

/// Write a line to stderr prefixed with a millisecond timestamp. A
/// drop-in replacement for `fputs(_, stderr)`.
func logStderr(_ s: String) {
    fputs(logTS() + s, stderr)
}
