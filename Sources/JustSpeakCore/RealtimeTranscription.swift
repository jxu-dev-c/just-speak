import Accelerate
import Foundation

public enum RealtimeError: Error, CustomStringConvertible, Equatable, Sendable {
  case missingAPIKey
  case server(String)
  case connection(String)
  case timeout
  case cancelled

  public var description: String {
    switch self {
    case .missingAPIKey: return "no OpenAI API key (set asr.openai.apiKey or OPENAI_API_KEY)"
    case .server(let msg): return "OpenAI transcription: \(msg)"
    case .connection(let msg): return "OpenAI connection: \(msg)"
    case .timeout: return "OpenAI transcription timed out"
    case .cancelled: return "OpenAI transcription cancelled"
    }
  }
}

/// The wire format of an OpenAI realtime transcription session, kept free of I/O so it can be tested.
public enum RealtimeProtocol {
  public static let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
  public static let sampleRate = 24_000

  public enum Event: Equatable, Sendable {
    case committed(itemID: String)
    case delta(itemID: String)
    case completed(itemID: String, transcript: String)
    case failed(String)
    case other
  }

  /// Keywords must be single-line and free of `<` and `>`, or the whole session update is rejected.
  public static func sanitizeKeywords(_ words: [String]) -> [String] {
    var seen = Set<String>()
    return words
      .map { $0.components(separatedBy: CharacterSet(charactersIn: "<>\r\n")).joined(separator: " ") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// `delay` only applies to streaming models; the retry model transcribes after commit.
  public static func sessionUpdate(model: String, config: Config.ASR.OpenAI, keywords: [String],
                                   streaming: Bool) -> [String: Any] {
    var transcription: [String: Any] = ["model": model]
    if streaming && !config.delay.isEmpty { transcription["delay"] = config.delay }
    let words = sanitizeKeywords(keywords)
    if !words.isEmpty { transcription["keywords"] = words }
    if !config.languages.isEmpty { transcription["languages"] = config.languages }
    if !config.prompt.isEmpty { transcription["prompt"] = config.prompt }
    return [
      "type": "session.update",
      "session": [
        "type": "transcription",
        "audio": [
          "input": [
            "format": ["type": "audio/pcm", "rate": sampleRate],
            "transcription": transcription,
            // our own hotkey release ends the turn
            "turn_detection": NSNull(),
          ] as [String: Any],
        ],
      ] as [String: Any],
    ]
  }

  /// Float samples in [-1, 1] → little-endian 16-bit PCM.
  public static func pcm16(_ samples: [Float]) -> Data {
    let ints = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)).littleEndian }
    return ints.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  public static func parse(_ text: String) -> Event {
    guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let type = json["type"] as? String
    else { return .other }
    let item = json["item_id"] as? String ?? ""
    let message = (json["error"] as? [String: Any])?["message"] as? String
    switch type {
    case "input_audio_buffer.committed": return .committed(itemID: item)
    case "conversation.item.input_audio_transcription.delta": return .delta(itemID: item)
    case "conversation.item.input_audio_transcription.completed":
      return .completed(itemID: item, transcript: json["transcript"] as? String ?? "")
    case "conversation.item.input_audio_transcription.failed": return .failed(message ?? "transcription failed")
    case "error": return .failed(message ?? "error")
    default: return .other
    }
  }
}

/// Settings and connection pool for OpenAI realtime transcription. One per config, like `Rewriter`.
public final class OpenAITranscriber: Sendable {
  let config: Config.ASR.OpenAI
  let keywords: [String]
  private let apiKey: String?
  /// One long-lived session so TLS is resumed between dictations.
  private let session: URLSession

  public init(config: Config.ASR.OpenAI, hotwords: [String], apiKey: String?) {
    self.config = config
    self.keywords = hotwords
    self.apiKey = apiKey
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 120  // idle time between socket messages, e.g. a long pause mid-dictation
    c.waitsForConnectivity = false
    session = URLSession(configuration: c)
  }

  /// Opens the connection right away, so the handshake overlaps the start of speech.
  public func makeSession() throws -> CloudDictation {
    guard let apiKey, !apiKey.isEmpty else { throw RealtimeError.missingAPIKey }
    return CloudDictation(transcriber: self, socket: socket(apiKey: apiKey), model: config.model, streaming: true)
  }

  /// Transcribe a whole recording in a fresh session (the retry after a failed stream).
  func transcribe(pcm: Data, model: String) async throws -> String {
    guard let apiKey, !apiKey.isEmpty else { throw RealtimeError.missingAPIKey }
    let d = CloudDictation(transcriber: self, socket: socket(apiKey: apiKey), model: model, streaming: false)
    d.append(pcm: pcm)
    return try await d.finalTranscript(requireSpeech: false)
  }

  private func socket(apiKey: String) -> RealtimeSocket {
    var req = URLRequest(url: RealtimeProtocol.url)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return RealtimeSocket(task: session.webSocketTask(with: req))
  }
}

/// A WebSocket that delivers parsed events. Messages sent before the handshake completes are queued.
final class RealtimeSocket: @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  var onEvent: (@Sendable (Result<RealtimeProtocol.Event, RealtimeError>) -> Void)?

  init(task: URLSessionWebSocketTask) {
    self.task = task
  }

  deinit {
    task.cancel(with: .goingAway, reason: nil)
  }

  func start() {
    task.resume()
    receive()
  }

  func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
      if let error, let self { self.onEvent?(.failure(self.connectionError(error))) }
    }
  }

  func close() {
    onEvent = nil
    task.cancel(with: .normalClosure, reason: nil)
  }

  private func receive() {
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(.string(let s)):
        self.onEvent?(.success(RealtimeProtocol.parse(s)))
        self.receive()
      case .success(.data(let d)):
        self.onEvent?(.success(RealtimeProtocol.parse(String(decoding: d, as: UTF8.self))))
        self.receive()
      case .success:
        self.receive()
      case .failure(let error):
        self.onEvent?(.failure(self.connectionError(error)))
      }
    }
  }

  /// A rejected handshake (bad key, no access) surfaces as a generic socket error; name the HTTP status instead.
  private func connectionError(_ error: Error) -> RealtimeError {
    if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
      return .connection("HTTP \(http.statusCode)")
    }
    return .connection(error.localizedDescription)
  }
}

/// One dictation streamed to OpenAI: audio is sent as it is recorded and transcribed as it arrives,
/// so at release only committing the turn and the last words are left. The PCM is kept in memory
/// (~2.9 MB per minute) for one retry of the whole clip if the stream fails.
public final class CloudDictation: Dictation, @unchecked Sendable {
  /// 20 ms frames louder than this count as speech; a recording with less than `minSpeechMs` of them is
  /// treated as silence and never committed (no cost, no transcript invented from room noise).
  static let speechRMS: Float = 0.003  // ≈ -50 dBFS
  static let minSpeechMs = 250

  private let queue = DispatchQueue(label: "just-speak.cloud", qos: .userInitiated)
  private let transcriber: OpenAITranscriber
  private let model: String
  // Only touched on `queue`.
  private var socket: RealtimeSocket?
  private var pcm = Data()
  private var speechSamples = 0
  private var itemID: String?
  private var finals: [String: String] = [:]  // completions for items not (yet) known as ours
  private var deltas = 0
  private var failure: RealtimeError?
  private var waiter: CheckedContinuation<String, Error>?

  public var sampleRate: Int { RealtimeProtocol.sampleRate }

  init(transcriber: OpenAITranscriber, socket: RealtimeSocket, model: String, streaming: Bool) {
    self.transcriber = transcriber
    self.model = model
    self.socket = socket
    socket.onEvent = { [weak self] event in
      guard let self else { return }
      self.queue.async { self.handle(event) }
    }
    socket.start()
    socket.send(RealtimeProtocol.sessionUpdate(model: model, config: transcriber.config,
                                               keywords: transcriber.keywords, streaming: streaming))
  }

  public func feed(_ chunk: [Float]) {
    queue.async {
      let frame = self.sampleRate / 50
      chunk.withUnsafeBufferPointer { buf in
        for start in stride(from: 0, to: buf.count, by: frame) {
          let n = min(frame, buf.count - start)
          var rms: Float = 0
          vDSP_rmsqv(buf.baseAddress! + start, 1, &rms, vDSP_Length(n))
          if rms > Self.speechRMS { self.speechSamples += n }
        }
      }
      self.sendLocked(RealtimeProtocol.pcm16(chunk))
    }
  }

  /// Append already-encoded PCM in ~200 ms messages (the retry path; the whole clip counts as speech).
  func append(pcm data: Data) {
    queue.async {
      let step = self.sampleRate / 5 * 2
      for start in stride(from: 0, to: data.count, by: step) {
        self.sendLocked(data.subdata(in: start..<min(start + step, data.count)))
      }
      self.speechSamples = data.count / 2
    }
  }

  public func finish() async throws -> DictationResult {
    let sw = Stopwatch()
    let (durationMs, speechMs, audio) = await withCheckedContinuation { cont in
      queue.async {
        cont.resume(returning: (self.pcm.count / 2 * 1000 / self.sampleRate,
                                self.speechSamples * 1000 / self.sampleRate, self.pcm))
      }
    }
    var retried = ""
    let text: String
    do {
      text = try await finalTranscript(requireSpeech: true)
    } catch {
      let retryModel = transcriber.config.retryModel
      guard !retryModel.isEmpty, (error as? RealtimeError) != .cancelled else { throw error }
      Log.info("asr stream failed after \(sw.ms)ms (\(error)); retrying with \(retryModel)")
      retried = " retry=\(retryModel)"
      text = try await transcriber.transcribe(pcm: audio, model: retryModel)
    }
    let deltas = await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.deltas) } }
    return DictationResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), durationMs: durationMs,
                           logDetail: "final=\(sw.ms)ms speech=\(speechMs)ms deltas=\(deltas)\(retried)")
  }

  /// Also ends a `finish` in progress (without its retry), e.g. when the hybrid's local decode won.
  public func cancel() {
    queue.async {
      self.resolveLocked(.failure(.cancelled))
      self.closeLocked()
      self.pcm = Data()
    }
  }

  /// Commit the turn and wait for its transcript; "" without speech (nothing is committed then).
  func finalTranscript(requireSpeech: Bool) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      queue.async {
        if requireSpeech && self.speechSamples * 1000 / self.sampleRate < Self.minSpeechMs {
          self.closeLocked()
          return cont.resume(returning: "")
        }
        if let failure = self.failure {
          self.closeLocked()
          return cont.resume(throwing: failure)
        }
        self.waiter = cont
        self.socket?.send(["type": "input_audio_buffer.commit"])
        self.queue.asyncAfter(deadline: .now() + .milliseconds(self.transcriber.config.timeoutMs)) {
          self.resolveLocked(.failure(.timeout))
        }
      }
    }
  }

  private func sendLocked(_ data: Data) {
    pcm.append(data)
    socket?.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
  }

  private func handle(_ event: Result<RealtimeProtocol.Event, RealtimeError>) {
    switch event {
    case .failure(let error):
      fail(error)
    case .success(.failed(let message)):
      fail(.server(message))
    case .success(.committed(let id)):
      itemID = id
      if let text = finals[id] { resolveLocked(.success(text)) }
    case .success(.delta):
      deltas += 1
    case .success(.completed(let id, let text)):
      if id == itemID { resolveLocked(.success(text)) } else { finals[id] = text }
    case .success(.other):
      break
    }
  }

  private func fail(_ error: RealtimeError) {
    if waiter != nil { resolveLocked(.failure(error)) } else if failure == nil { failure = error }
  }

  private func resolveLocked(_ result: Result<String, RealtimeError>) {
    guard let waiter else { return }
    self.waiter = nil
    closeLocked()
    waiter.resume(with: result.mapError { $0 as Error })
  }

  private func closeLocked() {
    socket?.close()
    socket = nil
  }
}
