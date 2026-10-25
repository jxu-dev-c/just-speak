import Foundation

public struct Config: Codable, Equatable, Sendable {
  public struct Hotkey: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case hold, toggle }
    /// rightOption | leftOption | rightCommand | rightControl | rightShift | fn
    public var key = "rightOption"
    public var mode = Mode.hold
    /// Hold mode: presses shorter than this are ignored (so a quick tap of the key does nothing).
    public var minHoldMs = 250
  }

  public struct ASR: Codable, Equatable, Sendable {
    public var modelDir = "~/Library/Application Support/just-speak/models/funasr-nano-int8-mmap"
    /// Silero VAD, used to split long dictation at pauses (see SpeechChunker).
    public var vadModel = "~/Library/Application Support/just-speak/models/silero_vad.onnx"
    public var numThreads = 4
    /// Empty = auto-detect. Otherwise a Fun-ASR language name, e.g. "中文", "英文", "日文".
    public var language = ""
    /// Inverse text normalization (spoken numbers → digits, etc.).
    public var itn = true
    /// Free the model after this many idle minutes; 0 keeps it resident.
    public var unloadAfterIdleMinutes = 10
  }

  public struct Rewrite: Codable, Equatable, Sendable {
    public var enabled = true
    public var endpoint = "https://api.inceptionlabs.ai/v1/chat/completions"
    public var model = "mercury-3"
    public var reasoningEffort = "instant"
    public var timeoutMs = 2500
    /// Transcripts shorter than this many characters are inserted as-is.
    public var minChars = 6
    /// Empty = INCEPTION_API_KEY from the environment or ~/.config/just-speak/.env.
    public var apiKey = ""
    /// nil = built-in prompt (see Rewriter.defaultSystemPrompt).
    public var systemPrompt: String? = nil
  }

  public struct Output: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable { case type, ax, paste }
    public enum Newlines: String, Codable, Sendable { case shiftReturn, keep, space }
    public var method = Method.type
    /// When a CJK input method is active, briefly switch to an ASCII layout while typing.
    public var switchToAsciiInputSource = true
    /// shiftReturn avoids sending a chat message halfway through; keep types a bare return.
    public var newlines = Newlines.shiftReturn
  }

  public struct Feedback: Codable, Equatable, Sendable {
    /// Floating "Listening…" pill with a level meter at the bottom of the screen.
    public var pill = true
    /// System sound names (/System/Library/Sounds); "" disables.
    public var startSound = "Tink"
    public var stopSound = "Pop"
    public var volume: Float = 0.35
  }

  public struct History: Codable, Equatable, Sendable {
    public var enabled = true
    /// Delete month files older than this many days; 0 keeps everything.
    public var retentionDays = 0
  }

  public var hotkey = Hotkey()
  public var hotwords: [String] = []
  public var asr = ASR()
  public var rewrite = Rewrite()
  public var output = Output()
  public var feedback = Feedback()
  public var history = History()

  public init() {}

  public var modelDirURL: URL { URL(fileURLWithPath: Paths.expand(asr.modelDir)) }
  public var vadModelURL: URL { URL(fileURLWithPath: Paths.expand(asr.vadModel)) }
}

// MARK: - Loading

public enum ConfigError: Error, CustomStringConvertible {
  case invalid(String)
  public var description: String {
    switch self {
    case .invalid(let msg): return "config.json: \(msg)"
    }
  }
}

extension Config {
  /// Parse user JSON (JSON5 allowed: comments, trailing commas) deep-merged over the defaults,
  /// so a config file only needs the keys it changes.
  public static func decode(_ data: Data) throws -> Config {
    let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
    let user: Any
    do {
      user = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
    } catch {
      throw ConfigError.invalid("not valid JSON (\(error.localizedDescription))")
    }
    guard let userDict = user as? [String: Any] else { throw ConfigError.invalid("top level must be an object") }
    let merged = deepMerge(defaults, userDict)
    do {
      return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
    } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.dataCorrupted(ctx) {
      let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
      throw ConfigError.invalid("bad value at \(path): \(ctx.debugDescription)")
    }
  }

  static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
    var out = base
    for (k, v) in over {
      if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
        out[k] = deepMerge(b, o)
      } else if !(v is NSNull) || base[k] == nil {
        out[k] = v
      }
    }
    return out
  }

  /// Load the config file, writing the defaults on first run.
  public static func loadOrCreate(at url: URL = Paths.configFile) throws -> Config {
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Config().prettyJSON().write(to: url, options: .atomic)
      return Config()
    }
    return try decode(Data(contentsOf: url))
  }

  public func prettyJSON() throws -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try enc.encode(self)
  }

  /// rewrite.apiKey, then $INCEPTION_API_KEY, then INCEPTION_API_KEY in ~/.config/just-speak/.env.
  public func resolvedAPIKey(env: [String: String] = ProcessInfo.processInfo.environment,
                             envFile: URL = Paths.envFile) -> String? {
    if !rewrite.apiKey.isEmpty { return rewrite.apiKey }
    if let k = env["INCEPTION_API_KEY"], !k.isEmpty { return k }
    guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      if parts.count == 2, parts[0] == "INCEPTION_API_KEY" {
        let v = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if !v.isEmpty { return v }
      }
    }
    return nil
  }
}
