import Foundation

private let logTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

/// Timestamped logging for long-running daemon components (supervisor,
/// auto-switch). One-shot CLI commands keep plain `print` — their output is
/// read interactively, not correlated against a timeline.
func log(_ message: String) {
    print("[\(logTimestampFormatter.string(from: Date()))] \(message)")
}
