import Foundation
import Testing
@testable import JustSpeakCore

final class ReplacementsStubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    guard let (status, body) = Self.handler?(request) else { return }
    let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
}

@Suite(.serialized) struct ReplacementsTests {
  @Test func appliesLongestSpokenPhraseCaseInsensitivelyWithWordBoundaries() {
    let rules = [
      "dot env": ".env",
      "env": ".env",
      "jay x u dev": "jxu-dev-c",
      "git": "Git",
      "大希律": "大希律王",
    ]
    let input = "Check the Dot Env and env files in jay x u dev with git (not digital) and 大希律."
    let output = TextReplacements.apply(input, replacements: rules)
    #expect(output == "Check the .env and .env files in jxu-dev-c with Git (not digital) and 大希律王.")
    // Idempotent when applied a second time (e.g. pre- and post-rewrite).
    #expect(TextReplacements.apply(output, replacements: rules) == output)
  }

  @Test func singlePassDoesNotChainReplacements() {
    let rules = [
      "alpha": "beta",
      "beta": "gamma",
    ]
    #expect(TextReplacements.apply("alpha and beta", replacements: rules) == "beta and gamma")
  }

  @Test func configDecodesAndMergesReplacementsDictionary() throws {
    let c = try Config.decode(Data(#"{"replacements": {"dot env": ".env", "jay x u": "jxu"}}"#.utf8))
    #expect(c.replacements == ["dot env": ".env", "jay x u": "jxu"])
    #expect(try Config.decode(c.prettyJSON()) == c)
  }

  @Test func rewriterIncludesReplacementsInSystemPromptAndAppliesDeterministically() async throws {
    let sc = URLSessionConfiguration.ephemeral
    sc.protocolClasses = [ReplacementsStubProtocol.self]
    let rewriter = Rewriter(config: .init(), apiKey: "k", session: URLSession(configuration: sc))
    let rules = ["dot env": ".env", "jay x u dev": "jxu-dev-c"]

    let prompt = rewriter.systemPrompt(hotwords: ["Mercury"], replacements: rules)
    #expect(prompt.contains("\"dot env\" -> \".env\""))
    #expect(prompt.contains("\"jay x u dev\" -> \"jxu-dev-c\""))

    let req = try rewriter.makeRequest(transcript: "update the dot env", hotwords: [], replacements: rules)
    let body = try #require(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
    let msgs = try #require(body["messages"] as? [[String: String]])
    #expect(msgs[0]["content"]?.contains("\"dot env\" -> \".env\"") == true)

    ReplacementsStubProtocol.handler = { _ in
      // Simulate LLM echoing an unreplaced phrase in its completion
      return (200, RewriterTests.completion("Updated the dot env in jay x u dev."))
    }

    let out = try await rewriter.rewrite("update the dot env in jay x u dev", hotwords: [], replacements: rules)
    #expect(out == "Updated the .env in jxu-dev-c.")
  }
}
