import Foundation
import Testing
@testable import JustSpeakCore

/// Serves canned responses so the rewriter can be tested without the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, TimeInterval))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    guard let (status, body, delay) = Self.handler?(request) else { return }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
      let resp = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: body)
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }
}

@Suite(.serialized) struct RewriterTests {
  func makeRewriter(timeoutMs: Int = 2500, apiKey: String? = "k", systemPrompt: String? = nil) -> Rewriter {
    var cfg = Config().rewrite
    cfg.timeoutMs = timeoutMs
    cfg.systemPrompt = systemPrompt
    let sc = URLSessionConfiguration.ephemeral
    sc.protocolClasses = [StubProtocol.self]
    sc.timeoutIntervalForRequest = Double(timeoutMs) / 1000
    return Rewriter(config: cfg, apiKey: apiKey, session: URLSession(configuration: sc))
  }

  static func completion(_ text: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
  }

  @Test func requestBodyCarriesModelEffortAndTranscript() throws {
    let req = try makeRewriter().makeRequest(transcript: "um hello", hotwords: ["Mercury"])
    let body = try #require(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
    #expect(body["model"] as? String == "mercury-3")
    #expect(body["reasoning_effort"] as? String == "instant")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages.last == ["role": "user", "content": "<transcript>\num hello\n</transcript>"])
    #expect(messages[0]["role"] == "system")
    #expect(messages[0]["content"]!.hasSuffix("Mercury"))
  }

  @Test func builtInPromptSendsExamplesAsTurns() {
    let messages = makeRewriter().messages(transcript: "x", hotwords: [])
    let examples = Rewriter.defaultExamples
    #expect(messages.count == 2 + 2 * examples.count)
    #expect(messages.dropFirst().map { $0["role"]! } == Array(repeating: ["user", "assistant"], count: examples.count)
      .flatMap { $0 } + ["user"])
    #expect(messages[1]["content"] == "<transcript>\n\(examples[0].transcript)\n</transcript>")
    #expect(messages[2]["content"] == examples[0].rewrite)
  }

  @Test func customPromptSkipsBuiltInExamples() {
    let messages = makeRewriter(systemPrompt: "Fix punctuation only.").messages(transcript: "x", hotwords: [])
    #expect(messages.map { $0["role"]! } == ["system", "user"])
    #expect(messages[0]["content"] == "Fix punctuation only.")
  }

  @Test func noHotwordsNoSpellingLine() {
    #expect(!makeRewriter().systemPrompt(hotwords: [" ", ""]).contains("Preferred spellings"))
  }

  @Test func parsesAndStripsEchoedTags() async throws {
    StubProtocol.handler = { _ in (200, Self.completion("<transcript>Hello.</transcript>\n"), 0) }
    #expect(try await makeRewriter().rewrite("um hello", hotwords: []) == "Hello.")
  }

  @Test func httpErrorThrows() async {
    StubProtocol.handler = { _ in (401, Data(#"{"error":"bad key"}"#.utf8), 0) }
    await #expect(throws: RewriteError.self) { try await makeRewriter().rewrite("x", hotwords: []) }
  }

  @Test func slowResponseTimesOut() async {
    StubProtocol.handler = { _ in (200, Self.completion("late"), 2) }
    let start = Date()
    await #expect(throws: (any Error).self) { try await makeRewriter(timeoutMs: 300).rewrite("x", hotwords: []) }
    #expect(Date().timeIntervalSince(start) < 1.5)
  }

  @Test func missingKeyThrowsBeforeNetwork() async {
    await #expect(throws: RewriteError.self) { try await makeRewriter(apiKey: nil).rewrite("x", hotwords: []) }
  }
}
