import Foundation

/// Append-only debug log at ~/Library/Logs/just-speak.log.
/// Only timings, sizes and errors go here — never transcript text (that lives in history).
public enum Log {
  private static let queue = DispatchQueue(label: "just-speak.log")
  nonisolated(unsafe) private static var handle: FileHandle?
  nonisolated(unsafe) public static var echoToStderr = false

  // only used on `queue`
  nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  public static func info(_ message: @autoclosure () -> String) {
    let now = Date()
    let msg = message()
    queue.async {
      let line = "\(formatter.string(from: now)) \(msg)\n"
      if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
      if handle == nil {
        let url = Paths.logFile
        try? FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
          FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
      }
      handle?.write(Data(line.utf8))
    }
  }
}

/// Monotonic stopwatch in milliseconds.
public struct Stopwatch: Sendable {
  private let start = DispatchTime.now().uptimeNanoseconds
  public init() {}
  public var ms: Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
}
