import Accelerate
import AppKit
import JustSpeakCore
import ServiceManagement

enum App {
  @MainActor static func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = AppController()
    app.delegate = controller
    app.run()
  }
}

/// hotkey → record → OpenAI realtime transcription (or Fun-ASR-Nano) → Mercury rewrite → type into focused app → local history.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
  private enum State {
    case idle
    case recording(startedAt: Date, app: String?)
    case processing
  }

  private var config = Config()
  private var state = State.idle
  private var session: (any Dictation)?
  private let recorder = AudioRecorder()
  private var transcriber: Transcriber!
  private var openAI: OpenAITranscriber!
  private var rewriter: Rewriter!
  private var history: HistoryStore?
  private var hotkey: HotkeyMonitor!
  private var status: StatusItem!
  private var watcher: ConfigWatcher?
  private var preloadWork: DispatchWorkItem?
  private var permissionTimer: Timer?
  private var lastText: String?
  private let orb = Orb()
  /// Whether the current recording has been confirmed as a dictation (sound played, orb shown).
  private var announced = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    status = StatusItem(actions: .init(
      openConfig: { NSWorkspace.shared.open(Paths.configFile) },
      revealHistory: { [weak self] in self?.revealHistory() },
      copyLast: { [weak self] in self?.copyLast() },
      unloadModel: { [weak self] in self?.transcriber.unload() },
      toggleLaunchAtLogin: { Self.toggleLaunchAtLogin() },
      launchAtLogin: { SMAppService.mainApp.status == .enabled },
      requestPermissions: { [weak self] in self?.requestPermissions(openSettings: true) },
      missingPermissions: { [weak self] in self?.missingPermissions().map(\.rawValue) ?? [] }
    ))

    do {
      config = try Config.loadOrCreate()
    } catch {
      status.set(.warning, message: "\(error) — using defaults")
    }
    transcriber = Transcriber(spec: modelSpec(config), unloadAfterIdleMinutes: config.asr.unloadAfterIdleMinutes)
    openAI = makeOpenAI(config)
    rewriter = Rewriter(config: config.rewrite, apiKey: config.resolvedAPIKey())
    hotkey = HotkeyMonitor(key: config.hotkey.key)
    hotkey.onEvent = { [weak self] in self?.handle($0) }
    setUpHistory()

    watcher = ConfigWatcher(url: Paths.configFile) { [weak self] in self?.reloadConfig() }
    watcher?.start()

    startHotkeyWhenPermitted()
    requestPermissions()
    Log.info("permissions: mic=\(AudioRecorder.permission.rawValue) accessibility=\(Inserter.hasAccessibility) "
      + "hotkeyActive=\(hotkey.isActive)")
    Log.info("started; footprint \(Int(ProcessStats.footprintMB))MB")
  }

  // MARK: - Pipeline

  private func handle(_ event: HotkeyMonitor.Event) {
    switch (config.hotkey.mode, event, state) {
    case (_, .cancelled, .recording):
      cancelRecording()
    case (_, .released, .idle), (_, .cancelled, .idle):
      preloadWork?.cancel()  // a pending "can't record" message for a press that turned out to be a tap
    case (.hold, .pressed, .idle), (.toggle, .pressed, .idle):
      beginRecording()
    case (.hold, .released, .recording(let startedAt, _)):
      if Date().timeIntervalSince(startedAt) * 1000 < Double(config.hotkey.minHoldMs) {
        cancelRecording()
      } else {
        finishRecording()
      }
    case (.toggle, .pressed, .recording):
      finishRecording()
    default:
      break
    }
  }

  private func makeDictation() throws -> any Dictation {
    switch config.asr.provider {
    case .openai:
      return try openAI.makeSession()
    case .local:
      return DictationSession(
        transcriber: transcriber, vadModel: config.vadModelURL,
        options: DecodeOptions(hotwords: config.hotwords, language: config.asr.language, itn: config.asr.itn))
    }
  }

  private func beginRecording() {
    let feedback = config.feedback
    let session: any Dictation
    let delay = config.hotkey.mode == .hold ? config.hotkey.minHoldMs : 0
    do {
      session = try makeDictation()
    } catch {
      status.set(.warning, message: "\(error)")
      // Only for a held press: a tap of the modifier (⌥←) shouldn't flash an error.
      let work = DispatchWorkItem { [weak self] in self?.orb.showMessage("\(error)") }
      preloadWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
      return
    }
    do {
      try recorder.start(sampleRate: session.sampleRate) { [weak self] samples in
        session.feed(samples)
        guard feedback.pill else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        Task { @MainActor in self?.orb.setLevel(rms) }
      }
    } catch {
      session.cancel()
      status.set(.warning, message: "microphone: \(error.localizedDescription)")
      orb.showMessage("Microphone unavailable: \(error.localizedDescription)")
      return
    }
    announced = false
    self.session = session
    Log.info("recording started")
    state = .recording(startedAt: Date(), app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    status.set(.recording)
    // Once the press has clearly become a dictation (not a stray tap of the modifier): give feedback,
    // and load the local model and open the rewrite connection while the user is still talking.
    // (The OpenAI socket is already connecting: a stray tap only costs a handshake.)
    let work = DispatchWorkItem { [weak self] in
      guard let self, case .recording = self.state else { return }
      self.announced = true
      self.playSound(self.config.feedback.startSound)
      if self.config.feedback.pill { self.orb.showListening() }
      if self.config.asr.provider == .local { self.transcriber.preload() }
      if self.config.rewrite.enabled { self.rewriter.warmUp() }
    }
    preloadWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
  }

  private func playSound(_ name: String) {
    guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
    sound.stop()
    sound.volume = config.feedback.volume
    sound.play()
  }

  private func cancelRecording() {
    preloadWork?.cancel()
    recorder.stop()
    session?.cancel()
    session = nil
    state = .idle
    status.set(.idle)
    if announced { orb.hide() }
    announced = false
  }

  private func finishRecording() {
    guard case .recording(_, let app) = state, let session else { return }
    preloadWork?.cancel()
    recorder.stop()
    self.session = nil
    state = .processing
    status.set(.processing)
    if announced {
      playSound(config.feedback.stopSound)
      if config.feedback.pill { orb.showProcessing() }
    }
    let cfg = config
    Task { await process(session, app: app, config: cfg) }
  }

  private func process(_ session: any Dictation, app: String?, config cfg: Config) async {
    defer { state = .idle }
    let total = Stopwatch()
    let result: DictationResult
    do {
      result = try await session.finish()
    } catch {
      Log.info("asr failed: \(error)")
      status.set(.warning, message: "\(error)")
      if cfg.feedback.pill { orb.showMessage("Transcription failed: \(error)") }
      return
    }
    let asrMs = total.ms  // only what was left at release; the rest was transcribed during speech
    let raw = result.text
    let durationMs = result.durationMs
    guard durationMs >= 300, !raw.isEmpty else {  // too short, or VAD heard no speech
      status.set(.idle)
      if cfg.feedback.pill { orb.shakeOff() }
      return
    }

    var rewritten: String?
    var rewriteMs: Int?
    if cfg.rewrite.enabled && raw.count >= cfg.rewrite.minChars {
      let sw = Stopwatch()
      do {
        rewritten = try await rewriter.rewrite(raw, hotwords: cfg.hotwords)
      } catch {
        // Never lose a dictation to the network: fall back to the raw transcript.
        Log.info("rewrite failed after \(sw.ms)ms: \(error)")
        status.set(.warning, message: "rewrite failed, inserted raw transcript")
      }
      rewriteMs = sw.ms
    }
    let text = rewritten ?? raw
    lastText = text

    if Inserter.hasAccessibility {
      if cfg.feedback.pill { orb.hide() }
      await Inserter.insert(text, config: cfg.output)
    } else {
      status.set(.warning, message: "Accessibility permission needed to insert text (use Copy Last Dictation)")
      if cfg.feedback.pill { orb.showMessage("Accessibility permission needed — use Copy Last Dictation") }
    }
    if status.phase != .warning { status.set(.idle) }
    status.lastSummary = "Last: \(String(format: "%.1f", Double(durationMs) / 1000))s audio → "
      + "asr \(asrMs)ms" + (rewriteMs.map { " + rewrite \($0)ms" } ?? "") + " (total \(total.ms)ms)"
    Log.info("dictation audio=\(durationMs)ms asr=\(asrMs)ms rewrite=\(rewriteMs.map(String.init) ?? "-")ms "
      + "total=\(total.ms)ms asr.provider=\(cfg.asr.provider.rawValue) \(result.logDetail) chars=\(text.count) "
      + "footprint=\(Int(ProcessStats.footprintMB))MB")

    history?.append(HistoryRecord(durationMs: durationMs, raw: raw, rewritten: rewritten, app: app,
                                  asrMs: asrMs, rewriteMs: rewriteMs))
  }

  // MARK: - Config

  private func modelSpec(_ c: Config) -> Transcriber.ModelSpec {
    .init(dir: c.modelDirURL, numThreads: c.asr.numThreads)
  }

  private func makeOpenAI(_ c: Config) -> OpenAITranscriber {
    OpenAITranscriber(config: c.asr.openai, hotwords: c.hotwords, apiKey: c.resolvedOpenAIKey())
  }

  private func reloadConfig() {
    let new: Config
    do {
      new = try Config.loadOrCreate()
    } catch {
      status.set(.warning, message: "\(error) — keeping previous config")
      return
    }
    guard new != config else { return }
    let old = config
    config = new
    if new.hotkey.key != old.hotkey.key { hotkey.setKey(new.hotkey.key) }
    if new.asr != old.asr {
      transcriber.update(spec: modelSpec(new), unloadAfterIdleMinutes: new.asr.unloadAfterIdleMinutes)
      if new.asr.provider == .openai && old.asr.provider == .local { transcriber.unload() }
    }
    if new.asr.openai != old.asr.openai || new.hotwords != old.hotwords { openAI = makeOpenAI(new) }
    if new.rewrite != old.rewrite { rewriter = Rewriter(config: new.rewrite, apiKey: new.resolvedAPIKey()) }
    if new.history != old.history { setUpHistory() }
    Log.info("config reloaded")
  }

  private func setUpHistory() {
    guard config.history.enabled else {
      history = nil
      return
    }
    if history == nil { history = HistoryStore() }
    history?.prune(retentionDays: config.history.retentionDays)
  }

  // MARK: - Permissions

  private enum Permission: String, CaseIterable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"

    var settingsURL: URL {
      let pane = switch self {
      case .microphone: "Privacy_Microphone"
      case .accessibility: "Privacy_Accessibility"
      }
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
  }

  private func missingPermissions() -> [Permission] {
    var missing: [Permission] = []
    if AudioRecorder.permission != .authorized { missing.append(.microphone) }
    // Accessibility covers both the hotkey monitor and typing into other apps.
    if !Inserter.hasAccessibility { missing.append(.accessibility) }
    return missing
  }

  /// At launch: trigger macOS's own prompts. They appear only once per app, so later requests
  /// (`openSettings: true`, from the menu) open the matching System Settings pane instead.
  private func requestPermissions(openSettings: Bool = false) {
    let missing = missingPermissions()
    if missing.contains(.microphone), AudioRecorder.permission == .notDetermined {
      Task { _ = await AudioRecorder.requestPermission() }
    }
    if missing.contains(.accessibility) { Inserter.requestAccessibility() }
    if openSettings, let first = missing.first {
      NSWorkspace.shared.open(first.settingsURL)
    }
  }

  /// The global key monitor only receives events once Accessibility is granted (out-of-process,
  /// in System Settings), so wait for that before installing it.
  private func startHotkeyWhenPermitted() {
    if Inserter.hasAccessibility {
      hotkey.start()
      return
    }
    status.set(.warning, message: "Accessibility permission needed for the hotkey and typing")
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, Inserter.hasAccessibility else { return }
        self.permissionTimer?.invalidate()
        self.permissionTimer = nil
        self.hotkey.start()
        self.status.set(.idle)
        Log.info("accessibility granted; hotkey active")
      }
    }
  }

  // MARK: - Menu actions

  private func revealHistory() {
    try? FileManager.default.createDirectory(at: Paths.historyDir, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([Paths.historyDir])
  }

  /// Explicit user action, so the clipboard is fair game here.
  private func copyLast() {
    guard let lastText else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lastText, forType: .string)
  }

  private static func toggleLaunchAtLogin() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      Log.info("launch at login: \(error)")
    }
  }
}
