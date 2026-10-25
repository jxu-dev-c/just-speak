import Foundation
import JustSpeakCore

let args = Array(CommandLine.arguments.dropFirst())

// No arguments (or Finder's -psn_ flag) → menu-bar app; otherwise a CLI subcommand.
if let cmd = args.first, !cmd.hasPrefix("-psn") {
  Task { exit(await CLI.run(cmd, Array(args.dropFirst()))) }
  // Not dispatchMain(): it exits the main thread, and AppKit (render-orb) needs main-actor work to run there.
  RunLoop.main.run()
} else {
  App.run()
}
