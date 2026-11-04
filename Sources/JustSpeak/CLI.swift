import AppKit
import JustSpeakCore

enum CLI {
  static let usage = """
    usage: just-speak                     run the menu-bar app
           just-speak setup                  download the local speech model (~1 GB, once; asr.provider "local")
           just-speak history [--since 7d|2026-10-01] [--grep TEXT] [--raw] [--json]
           just-speak transcribe [--provider openai|local|hybrid] [--hotwords a,b] [--realtime]
                                 [--threads N] [--whole] FILE.wav...
           just-speak rewrite TEXT           (or text on stdin)
           just-speak config-path
           just-speak render-orb DIR        write the README screenshots of the orb (light and dark)
    """

  static func run(_ cmd: String, _ args: [String]) async -> Int32 {
    do {
      switch cmd {
      case "setup": return try setup()
      case "history": return try history(args)
      case "transcribe": return try await transcribe(args)
      case "rewrite": return try await rewrite(args)
      case "render-orb": return try await renderOrb(args)
      case "config-path":
        print(Paths.configFile.path)
        return 0
      case "help", "-h", "--help":
        print(usage)
        return 0
      default:
        FileHandle.standardError.write(Data("unknown command \(cmd)\n\(usage)\n".utf8))
        return 2
      }
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      return 1
    }
  }

  /// Runs fetch-models.sh: the copy bundled in JustSpeak.app, or the repo's for `swift run`.
  static func setup() throws -> Int32 {
    // resolve first: via Homebrew's bin/ symlink, Bundle.main is bin/, not the app
    let bundled = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
      .appendingPathComponent("../Resources/fetch-models.sh").standardizedFileURL
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../scripts/fetch-models.sh").standardizedFileURL
    guard let script = [bundled, repo].compactMap({ $0 }).first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    }) else {
      FileHandle.standardError.write(Data("error: fetch-models.sh not found\n".utf8))
      return 1
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path]
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  static func history(_ args: [String]) throws -> Int32 {
    var since: Date?
    var grep: String?
    var json = false
    var showRaw = false
    var it = args.makeIterator()
    while let a = it.next() {
      switch a {
      case "--since":
        guard let v = it.next(), let d = parseSince(v) else {
          throw ConfigError.invalid("--since takes e.g. 30m, 12h, 7d or 2026-10-01")
        }
        since = d
      case "--grep": grep = it.next()
      case "--json": json = true
      case "--raw": showRaw = true
      default: throw ConfigError.invalid("unknown history option \(a)")
      }
    }

    let store = HistoryStore()
    var (records, unreadable) = try store.read(since: since)
    if let grep {
      records = records.filter {
        $0.raw.localizedCaseInsensitiveContains(grep) || ($0.rewritten?.localizedCaseInsensitiveContains(grep) ?? false)
      }
    }

    if json {
      let enc = JSONEncoder()
      enc.dateEncodingStrategy = .iso8601
      enc.outputFormatting = [.withoutEscapingSlashes]
      for r in records { print(String(decoding: try enc.encode(r), as: UTF8.self)) }
    } else {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd HH:mm"
      for r in records {
        print("\(f.string(from: r.ts))  \(r.app ?? "")")
        print("  \(r.text)")
        if showRaw && r.rewritten != nil { print("  raw: \(r.raw)") }
      }
    }
    if unreadable > 0 {
      FileHandle.standardError.write(Data("\(unreadable) line(s) could not be parsed\n".utf8))
    }
    return 0
  }

  static func parseSince(_ s: String) -> Date? {
    if let unit = s.last, let n = Double(s.dropLast()) {
      let seconds: Double? = switch unit {
      case "m": n * 60
      case "h": n * 3600
      case "d": n * 86400
      default: nil
      }
      if let seconds { return Date().addingTimeInterval(-seconds) }
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
  }

  /// Runs the same pipeline as the app, feeding each file in 100 ms blocks like the mic does; the reported
  /// asr time is what is left after the last block, i.e. the latency at hotkey release.
  /// Local only: `--whole` decodes each file in one pass instead (no VAD), `--ep` picks the onnxruntime provider.
  static func transcribe(_ args: [String]) async throws -> Int32 {
    var config = try Config.loadOrCreate()
    var files: [String] = []
    var executionProvider = "cpu"
    var whole = false
    var realtime = false
    var it = args.makeIterator()
    while let a = it.next() {
      switch a {
      case "--provider":
        guard let p = it.next().flatMap(Config.ASR.Provider.init(rawValue:)) else {
          throw ConfigError.invalid("--provider takes openai, local or hybrid")
        }
        config.asr.provider = p
      case "--threads": config.asr.numThreads = Int(it.next() ?? "") ?? config.asr.numThreads
      case "--ep": executionProvider = it.next() ?? executionProvider
      case "--hotwords": config.hotwords = (it.next() ?? "").split(separator: ",").map(String.init)
      case "--whole": whole = true
      case "--realtime": realtime = true
      default: files.append(a)
      }
    }
    if config.asr.provider == .openai {
      let openAI = OpenAITranscriber(config: config.asr.openai, hotwords: config.hotwords,
                                     apiKey: config.resolvedOpenAIKey())
      for f in files {
        guard let w = Wave.read(f) else { print("cannot read \(f)"); continue }
        let session = try openAI.makeSession()
        try await feed(Resample.linear(w.samples, from: w.sampleRate, to: session.sampleRate), to: session,
                       realtime: realtime)
        let t = Stopwatch()
        let result = try await session.finish()
        report(f, audioMs: result.durationMs, asrMs: t.ms, chunks: 1, text: result.text)
        print("  \(result.logDetail)")
      }
      return 0
    }

    let opts = DecodeOptions(hotwords: config.hotwords, language: config.asr.language, itn: config.asr.itn)
    let sw = Stopwatch()

    if whole {
      let model = try FunASRNano(modelDir: config.modelDirURL, numThreads: config.asr.numThreads,
                                 provider: executionProvider)
      print(String(format: "load %dms  footprint %.0fMB", sw.ms, ProcessStats.footprintMB))
      for f in files {
        guard let w = Wave.read(f) else { print("cannot read \(f)"); continue }
        let t = Stopwatch()
        let text = model.transcribe(w.samples, sampleRate: w.sampleRate, options: opts)
        report(f, audioMs: w.samples.count * 1000 / w.sampleRate, asrMs: t.ms, chunks: 1, text: text)
      }
      return 0
    }

    let transcriber = Transcriber(spec: .init(dir: config.modelDirURL, numThreads: config.asr.numThreads),
                                  unloadAfterIdleMinutes: 0)
    transcriber.preload()
    for f in files {
      guard let w = Wave.read(f), w.sampleRate == SpeechChunker.sampleRate else {
        print("cannot read \(f) (need 16 kHz mono 16-bit WAV)")
        continue
      }
      if config.asr.provider == .hybrid {
        let openAI = OpenAITranscriber(config: config.asr.openai, hotwords: config.hotwords,
                                       apiKey: config.resolvedOpenAIKey())
        let session = HybridDictation(
          local: DictationSession(transcriber: transcriber, vadModel: config.vadModelURL, options: opts),
          cloud: try openAI.makeSession(), transcriber: transcriber, localMaxMs: config.asr.hybrid.localMaxMs)
        try await feed(w.samples, to: session, realtime: realtime)
        let t = Stopwatch()
        let result = try await session.finish()
        report(f, audioMs: result.durationMs, asrMs: t.ms, chunks: 0, text: result.text)
        print("  \(result.logDetail)")
        continue
      }
      let session = DictationSession(transcriber: transcriber, vadModel: config.vadModelURL, options: opts)
      try await feed(w.samples, to: session, realtime: realtime)
      let t = Stopwatch()
      let result = try await session.finishWithChunks()
      let spans = result.chunks.map { String(format: "%.1f–%.1fs", Double($0.lowerBound) / 16000, Double($0.upperBound) / 16000) }
      report(f, audioMs: result.durationMs, asrMs: t.ms, chunks: result.chunks.count, text: result.text)
      print("  chunks: \(spans.joined(separator: ", "))  tail \(result.tailMs)ms"
        + (result.tailReused ? " (decoded before release)" : ""))
    }
    return 0
  }

  private static func feed(_ samples: [Float], to session: any Dictation, realtime: Bool) async throws {
    let block = session.sampleRate / 10
    for i in stride(from: 0, to: samples.count, by: block) {
      session.feed(Array(samples[i..<min(i + block, samples.count)]))
      if realtime { try await Task.sleep(for: .milliseconds(100)) }  // pace like a live mic
    }
  }

  private static func report(_ file: String, audioMs: Int, asrMs: Int, chunks: Int, text: String) {
    print(String(format: "%@  audio %dms  asr %dms  rtf %.3f  chunks %d  footprint %.0fMB\n  %@",
                 (file as NSString).lastPathComponent, audioMs, asrMs, Double(asrMs) / Double(max(audioMs, 1)),
                 chunks, ProcessStats.footprintMB, text))
  }

  @MainActor
  static func renderOrb(_ args: [String]) throws -> Int32 {
    guard let dir = args.first.map({ URL(fileURLWithPath: $0) }) else {
      throw ConfigError.invalid("render-orb takes an output directory")
    }
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let variants: [(String, NSColor, NSColor)] = [
      ("orb-light.png", NSColor(srgbRed: 0.99, green: 0.91, blue: 0.90, alpha: 1),
       NSColor(srgbRed: 0.86, green: 0.90, blue: 0.99, alpha: 1)),
      ("orb-dark.png", NSColor(srgbRed: 0.24, green: 0.10, blue: 0.20, alpha: 1),
       NSColor(srgbRed: 0.08, green: 0.10, blue: 0.20, alpha: 1)),
    ]
    for (name, from, to) in variants {
      guard let rep = Orb.renderSnapshot(backdrop: (from, to), canvas: NSSize(width: 520, height: 180), level: 0.45),
            let png = rep.representation(using: .png, properties: [:])
      else { throw ConfigError.invalid("could not render \(name)") }
      let url = dir.appendingPathComponent(name)
      try png.write(to: url)
      print(url.path)
    }
    return 0
  }

  static func rewrite(_ args: [String]) async throws -> Int32 {
    let config = try Config.loadOrCreate()
    var text = args.joined(separator: " ")
    if text.isEmpty { text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
    let rewriter = Rewriter(config: config.rewrite, apiKey: config.resolvedAPIKey())
    let sw = Stopwatch()
    let out = try await rewriter.rewrite(text, hotwords: config.hotwords)
    FileHandle.standardError.write(Data("rewrite \(sw.ms)ms\n".utf8))
    print(out)
    return 0
  }
}
