import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct AppOverridesTests {
  @Test func decodesAndMergesPerAppOverrides() throws {
    let json = """
      {
        "rewrite": {
          "appOverrides": {
            "com.apple.Terminal": { "enabled": false, "newlines": "keep" },
            "com.tinyspeck.slackmacgap": { "systemPrompt": "Keep it casual." },
            "com.jetbrains.*": { "enabled": false }
          }
        }
      }
      """
    let cfg = try Config.decode(Data(json.utf8))
    #expect(cfg.rewrite.appOverrides.count == 3)

    let term = cfg.forApp(bundleID: "com.apple.Terminal")
    #expect(term.rewrite.enabled == false)
    #expect(term.output.newlines == .keep)
    #expect(term.rewrite.systemPrompt == nil)

    let slack = cfg.forApp(bundleID: "com.tinyspeck.slackmacgap")
    #expect(slack.rewrite.enabled == true)
    #expect(slack.rewrite.systemPrompt == "Keep it casual.")
    #expect(slack.output.newlines == .shiftReturn)

    let idea = cfg.forApp(bundleID: "com.jetbrains.intellij")
    #expect(idea.rewrite.enabled == false)

    let other = cfg.forApp(bundleID: "com.apple.mail")
    #expect(other == cfg)
  }

  @Test func matchingPrecedencePrefersExactOverGlobAndSupportsAppName() throws {
    var cfg = Config()
    cfg.rewrite.appOverrides = [
      "com.jetbrains.*": .init(enabled: false, systemPrompt: "glob"),
      "com.jetbrains.fleet": .init(enabled: true, systemPrompt: "exact-bundle"),
      "Slack": .init(enabled: true, systemPrompt: "by-name", newlines: .space),
      "*code*": .init(enabled: false, systemPrompt: "code-glob"),
    ]

    let fleet = cfg.forApp(bundleID: "com.jetbrains.fleet", appName: "Fleet")
    #expect(fleet.rewrite.enabled == true)
    #expect(fleet.rewrite.systemPrompt == "exact-bundle")

    let pycharm = cfg.forApp(bundleID: "com.jetbrains.pycharm", appName: "PyCharm")
    #expect(pycharm.rewrite.enabled == false)
    #expect(pycharm.rewrite.systemPrompt == "glob")

    let slackByName = cfg.forApp(bundleID: "com.unknown.bundle", appName: "slack")
    #expect(slackByName.rewrite.systemPrompt == "by-name")
    #expect(slackByName.output.newlines == .space)

    let vscode = cfg.forApp(bundleID: "com.microsoft.VSCode", appName: "Visual Studio Code")
    #expect(vscode.rewrite.enabled == false)
    #expect(vscode.rewrite.systemPrompt == "code-glob")
  }

  @Test func rewriterForAppUsesOverriddenSystemPromptAndSkipsDefaultExamples() {
    var cfg = Config().rewrite
    cfg.appOverrides = [
      "com.tinyspeck.slackmacgap": .init(systemPrompt: "Casual Slack tone.")
    ]
    let base = Rewriter(config: cfg, apiKey: "k")
    let slackRewriter = base.forApp(bundleID: "com.tinyspeck.slackmacgap")
    let msgs = slackRewriter.messages(transcript: "um hey team", hotwords: ["Mercury"])
    #expect(msgs.map { $0["role"]! } == ["system", "user"])
    #expect(msgs[0]["content"]!.hasPrefix("Casual Slack tone."))
    #expect(msgs[0]["content"]!.hasSuffix("Mercury"))

    let defaultRewriter = base.forApp(bundleID: "com.apple.mail")
    let defaultMsgs = defaultRewriter.messages(transcript: "um hey team", hotwords: [])
    #expect(defaultMsgs.count == 2 + 2 * Rewriter.defaultExamples.count)
  }
}
