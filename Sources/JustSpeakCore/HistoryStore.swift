import Foundation

public struct HistoryRecord: Codable, Equatable, Sendable {
  public var ts: Date
  public var durationMs: Int
  public var raw: String
  /// nil when the rewrite was skipped or failed (the raw transcript was inserted).
  public var rewritten: String?
  /// Bundle id of the app the text was inserted into.
  public var app: String?
  public var asrMs: Int
  public var rewriteMs: Int?

  public init(ts: Date = Date(), durationMs: Int, raw: String, rewritten: String?, app: String?,
              asrMs: Int, rewriteMs: Int?) {
    self.ts = ts
    self.durationMs = durationMs
    self.raw = raw
    self.rewritten = rewritten
    self.app = app
    self.asrMs = asrMs
    self.rewriteMs = rewriteMs
  }

  public var text: String { rewritten ?? raw }
}

/// Transcript history: one JSONL file per month (`YYYY-MM.jsonl`), one record per line.
/// Plain JSON so it can be read with any tool (`jq`, `grep`); the files are owner-only (0600).
public final class HistoryStore: @unchecked Sendable {
  public let directory: URL
  private let queue = DispatchQueue(label: "just-speak.history")

  public init(directory: URL = Paths.historyDir) {
    self.directory = directory
  }

  private static let monthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM"
    return f
  }()

  static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
  }

  private static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }

  func fileURL(for date: Date) -> URL {
    directory.appendingPathComponent("\(Self.monthFormatter.string(from: date)).jsonl")
  }

  /// Append asynchronously; never blocks the dictation path.
  public func append(_ record: HistoryRecord) {
    queue.async {
      do {
        let line = try Self.encoder().encode(record) + Data("\n".utf8)
        let url = self.fileURL(for: record.ts)
        let fm = FileManager.default
        try fm.createDirectory(at: self.directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
          fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
      } catch {
        Log.info("history append failed: \(error)")
      }
    }
  }

  /// Wait for pending appends (used by tests and before exit).
  public func flush() { queue.sync {} }

  /// All records at or after `since`, oldest first. Lines that fail to parse are counted, not fatal.
  public func read(since: Date? = nil) throws -> (records: [HistoryRecord], unreadable: Int) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return ([], 0) }
    let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jsonl" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let decoder = Self.decoder()
    var out: [HistoryRecord] = []
    var bad = 0
    let sinceMonth = since.map { Self.monthFormatter.string(from: $0) }
    for f in files {
      if let sinceMonth, f.deletingPathExtension().lastPathComponent < sinceMonth { continue }
      for line in try String(contentsOf: f, encoding: .utf8).split(whereSeparator: \.isNewline) {
        guard let r = try? decoder.decode(HistoryRecord.self, from: Data(line.utf8)) else {
          bad += 1
          continue
        }
        if let since, r.ts < since { continue }
        out.append(r)
      }
    }
    return (out, bad)
  }

  /// Delete month files whose every record is older than `days`.
  public func prune(retentionDays days: Int, now: Date = Date()) {
    guard days > 0 else { return }
    queue.async {
      let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now)!
      // A month file can hold records newer than the cutoff until the month after the cutoff's month.
      let keepFrom = Self.monthFormatter.string(from: cutoff)
      let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
      for f in files where f.pathExtension == "jsonl" && f.deletingPathExtension().lastPathComponent < keepFrom {
        try? FileManager.default.removeItem(at: f)
        Log.info("history pruned \(f.lastPathComponent)")
      }
    }
  }
}
