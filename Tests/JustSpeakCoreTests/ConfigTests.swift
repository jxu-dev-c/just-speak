import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct ConfigTests {
  @Test func emptyObjectGivesDefaults() throws {
    #expect(try Config.decode(Data("{}".utf8)) == Config())
  }

  @Test func partialConfigMergesOverDefaults() throws {
    let c = try Config.decode(Data(#"{"hotwords": ["Mercury"], "asr": {"numThreads": 6}}"#.utf8))
    #expect(c.hotwords == ["Mercury"])
    #expect(c.asr.numThreads == 6)
    #expect(c.asr.itn == true)                      // sibling key keeps its default
    #expect(c.rewrite.model == "mercury-3")
  }

  @Test func json5CommentsAndTrailingCommas() throws {
    let c = try Config.decode(Data("""
      {
        // push-to-talk on the right command key
        "hotkey": { "key": "rightCommand", "mode": "toggle", },
      }
      """.utf8))
    #expect(c.hotkey.key == "rightCommand")
    #expect(c.hotkey.mode == .toggle)
  }

  @Test func systemPromptCanBeSetAndNulled() throws {
    #expect(try Config.decode(Data(#"{"rewrite": {"systemPrompt": "x"}}"#.utf8)).rewrite.systemPrompt == "x")
    #expect(try Config.decode(Data(#"{"rewrite": {"systemPrompt": null}}"#.utf8)).rewrite.systemPrompt == nil)
  }

  @Test func badValueNamesThePath() {
    #expect {
      try Config.decode(Data(#"{"output": {"method": "teleport"}}"#.utf8))
    } throws: { "\($0)".contains("output.method") }
  }

  @Test func roundTripsThroughPrettyJSON() throws {
    var c = Config()
    c.hotwords = ["sherpa-onnx", "大希律王"]
    c.output.method = .ax
    #expect(try Config.decode(c.prettyJSON()) == c)
  }

  @Test func apiKeyResolutionOrder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let envFile = dir.appendingPathComponent(".env")
    try "# comment\nINCEPTION_API_KEY=\"from-file\"\n".write(to: envFile, atomically: true, encoding: .utf8)

    var c = Config()
    #expect(c.resolvedAPIKey(env: [:], envFile: envFile) == "from-file")
    #expect(c.resolvedAPIKey(env: ["INCEPTION_API_KEY": "from-env"], envFile: envFile) == "from-env")
    c.rewrite.apiKey = "from-config"
    #expect(c.resolvedAPIKey(env: ["INCEPTION_API_KEY": "from-env"], envFile: envFile) == "from-config")
    #expect(Config().resolvedAPIKey(env: [:], envFile: dir.appendingPathComponent("missing")) == nil)
  }
}
