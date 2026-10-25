import Foundation
import JustSpeakCore

let args = Array(CommandLine.arguments.dropFirst())

// No arguments (or Finder's -psn_ flag) → menu-bar app; otherwise a CLI subcommand.
if let cmd = args.first, !cmd.hasPrefix("-psn") {
  Task { exit(await CLI.run(cmd, Array(args.dropFirst()))) }
  dispatchMain()
} else {
  App.run()
}
