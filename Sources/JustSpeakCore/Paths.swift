import Foundation

public enum Paths {
  public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  /// `$XDG_CONFIG_HOME/just-speak`, defaulting to `~/.config/just-speak`.
  public static var configDir: URL {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg).appendingPathComponent("just-speak")
    }
    return home.appendingPathComponent(".config/just-speak")
  }

  public static var configFile: URL { configDir.appendingPathComponent("config.json") }
  public static var envFile: URL { configDir.appendingPathComponent(".env") }

  public static var appSupport: URL {
    home.appendingPathComponent("Library/Application Support/just-speak")
  }

  public static var historyDir: URL { appSupport.appendingPathComponent("history") }
  public static var modelsDir: URL { appSupport.appendingPathComponent("models") }
  public static var logFile: URL { home.appendingPathComponent("Library/Logs/just-speak.log") }

  /// Expand a leading `~` the way a shell would.
  public static func expand(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }
}
