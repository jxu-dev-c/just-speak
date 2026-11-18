import Foundation
import Testing
@testable import JustSpeakCore

@Suite(.serialized) struct ConfigWatcherTests {
  @MainActor
  @Test func detectsInPlaceAndAtomicSavesAndRebindsAfterRename() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("js-watcher-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("config.json")
    try #"{"hotwords": ["initial"]}"#.write(to: file, atomically: true, encoding: .utf8)

    var changes = 0
    let watcher = ConfigFileWatcher(url: file, debounceInterval: 0.05) {
      changes += 1
    }
    watcher.start()
    defer { watcher.stop() }

    // 1. In-place save (non-atomic write directly to existing inode)
    try #"{"hotwords": ["in-place-1"]}"#.write(to: file, atomically: false, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(150))
    #expect(changes == 1, "in-place save should trigger onChange")

    // 2. Atomic save (temp file + rename replacing inode)
    try #"{"hotwords": ["atomic-2"]}"#.write(to: file, atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(150))
    #expect(changes == 2, "atomic save should trigger onChange")

    // 3. Another in-place save after atomic rename (verifies fileSource rebound to new inode)
    try #"{"hotwords": ["in-place-after-rename"]}"#.write(to: file, atomically: false, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(150))
    #expect(changes == 3, "in-place save after atomic rename should still trigger onChange")
  }
}
