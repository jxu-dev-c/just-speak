import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct RealtimeTranscriptionTests {
  private func transcription(_ update: [String: Any]) -> [String: Any] {
    let session = update["session"] as! [String: Any]
    let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
    return input["transcription"] as! [String: Any]
  }

  @Test func sessionUpdateShape() throws {
    let update = RealtimeProtocol.sessionUpdate(model: "gpt-live-transcribe", config: .init(),
                                                keywords: ["Mercury"], streaming: true)
    #expect(update["type"] as? String == "session.update")
    let session = update["session"] as! [String: Any]
    #expect(session["type"] as? String == "transcription")
    let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
    #expect(input["turn_detection"] is NSNull)
    let format = input["format"] as! [String: Any]
    #expect(format["type"] as? String == "audio/pcm")
    #expect(format["rate"] as? Int == 24_000)

    let t = transcription(update)
    #expect(t["model"] as? String == "gpt-live-transcribe")
    #expect(t["delay"] as? String == "medium")
    #expect(t["keywords"] as? [String] == ["Mercury"])
    // empty settings are left out, and the singular `language` is never sent
    #expect(t["languages"] == nil && t["prompt"] == nil && t["language"] == nil)
    // must serialize as-is
    _ = try JSONSerialization.data(withJSONObject: update)
  }

  @Test func retrySessionOmitsDelayAndKeepsContext() {
    var c = Config.ASR.OpenAI()
    c.languages = ["en", "zh"]
    c.prompt = "Dictation"
    let t = transcription(RealtimeProtocol.sessionUpdate(model: "gpt-transcribe", config: c, keywords: [],
                                                         streaming: false))
    #expect(t["delay"] == nil)
    #expect(t["keywords"] == nil)
    #expect(t["languages"] as? [String] == ["en", "zh"])
    #expect(t["prompt"] as? String == "Dictation")
  }

  @Test func keywordsAreSanitized() {
    #expect(RealtimeProtocol.sanitizeKeywords(["<b>Mercury</b>", "two\nlines", "  ", "Mercury", "a\r"])
      == ["b Mercury /b", "two lines", "Mercury", "a"])
  }

  @Test func pcm16ClipsAndIsLittleEndian() {
    let data = RealtimeProtocol.pcm16([0, 1, -1, 2, -2, 0.5])
    let ints = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map(Int16.init(littleEndian:))
    #expect(ints == [0, 32767, -32767, 32767, -32767, 16383])
    #expect(Array(RealtimeProtocol.pcm16([1])) == [0xFF, 0x7F])
  }

  @Test func parsesEvents() {
    let p = RealtimeProtocol.parse
    #expect(p(#"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#) == .committed(itemID: "item_1"))
    #expect(p(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"Hi"}"#)
      == .delta(itemID: "item_1", text: "Hi"))
    #expect(p(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1"}"#)
      == .delta(itemID: "item_1", text: ""))
    #expect(p(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Hi."}"#)
      == .completed(itemID: "item_1", transcript: "Hi."))
    #expect(p(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"item_1","error":{"message":"boom"}}"#)
      == .failed("boom"))
    #expect(p(#"{"type":"error","error":{"message":"Invalid value"}}"#) == .failed("Invalid value"))
    #expect(p(#"{"type":"session.updated"}"#) == .other)
    #expect(p("not json") == .other)
  }

  @Test func linearResample() {
    #expect(Resample.linear([1, 2, 3], from: 16_000, to: 16_000) == [1, 2, 3])
    let up = Resample.linear([0, 2, 4, 6], from: 16_000, to: 24_000)
    #expect(up.count == 6)
    #expect(up.first == 0)
    #expect(abs(up[1] - 4.0 / 3) < 1e-5)  // x = 2/3 between 0 and 2
    #expect(abs(up[3] - 4) < 1e-5)        // x = 2 lands on a source sample
  }
}
