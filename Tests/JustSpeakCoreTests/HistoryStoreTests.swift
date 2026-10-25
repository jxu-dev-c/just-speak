import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct HistoryStoreTests {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("js-history-\(UUID().uuidString)")

  func record(_ text: String, at ts: Date = Date()) -> HistoryRecord {
    HistoryRecord(ts: ts, durationMs: 1200, raw: "um \(text)", rewritten: text, app: "com.apple.TextEdit",
                  asrMs: 300, rewriteMs: 400)
  }

  @Test func appendAndReadBack() throws {
    let store = HistoryStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    store.append(record("hello 世界"))
    store.append(record("second"))
    store.flush()
    let (records, bad) = try store.read()
    #expect(records.map(\.text) == ["hello 世界", "second"])
    #expect(bad == 0)
  }

  @Test func filesArePlainJSONLinesOwnerOnly() throws {
    let store = HistoryStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    store.append(record("readable words"))
    store.flush()
    let file = store.fileURL(for: Date())
    let line = try #require(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
    let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(obj["rewritten"] as? String == "readable words")
    let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
  }

  @Test func corruptLinesAreCountedNotFatal() throws {
    let store = HistoryStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    store.append(record("kept"))
    store.flush()
    let h = try FileHandle(forWritingTo: store.fileURL(for: Date()))
    try h.seekToEnd()
    try h.write(contentsOf: Data("{\"half\": \nnot json\n".utf8))
    try h.close()
    let (records, bad) = try store.read()
    #expect(records.map(\.text) == ["kept"])
    #expect(bad == 2)
  }

  @Test func sinceFiltersRecords() throws {
    let store = HistoryStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    store.append(record("old", at: Date().addingTimeInterval(-86400 * 40)))
    store.append(record("new"))
    store.flush()
    #expect(try store.read(since: Date().addingTimeInterval(-3600)).records.map(\.text) == ["new"])
    #expect(try store.read().records.count == 2)
  }

  @Test func pruneDropsOnlyOldMonths() throws {
    let store = HistoryStore(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    store.append(record("ancient", at: Date().addingTimeInterval(-86400 * 120)))
    store.append(record("recent"))
    store.prune(retentionDays: 30)
    store.flush()
    #expect(try store.read().records.map(\.text) == ["recent"])
  }
}
