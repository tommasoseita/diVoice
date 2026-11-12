import DiVoiceCore
import Foundation

public enum TranscriptionPath: String, Codable, Sendable {
  case realtime
  case batch
  case batchFallback = "batch_fallback"
  case realtimeFallback = "realtime_fallback"
  case none
}

public struct TranscriptOutcome: Sendable, Equatable {
  public var text: String
  public var path: TranscriptionPath
  public var model: String
  public var warning: String?
}

/// Transcription of one recording: streaming while speaking and/or batch at release,
/// according to the mode, each one the fallback of the other.
public actor TranscriptionRun {
  public static let minAudioMs = 250
  static let maxAudioSeconds = 600

  private let service: TranscriptionService
  private let settings: TranscriptionSettings
  private let language: String?
  private var vocabulary: [String]
  private var previousText: String?
  private let sampleRate: Int
  private var transcriber: StreamingTranscriber?
  private var audio = Data()
  public private(set) var upstreamConnectMs: Double?

  public init(service: TranscriptionService, settings: TranscriptionSettings, language: String?, vocabulary: [String], sampleRate: Int) {
    self.service = service
    self.settings = settings
    self.language = language
    self.vocabulary = vocabulary
    self.sampleRate = sampleRate
  }

  private func request(_ model: String) -> TranscriptionRequest {
    TranscriptionRequest(
      model: model, language: language, vocabulary: vocabulary, delayMs: settings.delayMs, sampleRate: sampleRate, previousText: previousText)
  }

  /// Names read on screen, after the dictionary's terms: only before the streaming opens.
  public func addTerms(_ terms: [String]) {
    guard transcriber == nil else { return }
    var seen = Set(vocabulary.map { $0.lowercased() })
    vocabulary += terms.filter { seen.insert($0.lowercased()).inserted }
  }

  /// The text already in the field: only before the streaming opens.
  public func setPreviousText(_ text: String?) {
    guard transcriber == nil else { return }
    previousText = text
  }

  public func start(onText: (@Sendable (String) -> Void)? = nil) {
    guard settings.mode != .batch, transcriber == nil else { return }
    transcriber = service.openStreaming(request(settings.realtimeModel), onText: onText)
  }

  public func append(_ chunk: Data) async throws {
    guard audio.count + chunk.count <= Self.maxAudioSeconds * sampleRate * 2 else {
      throw EngineError("recording too long (10 minutes at most)")
    }
    audio.append(chunk)
    await transcriber?.sendAudio(chunk)
  }

  public var audioMs: Int { audio.count * 1000 / (sampleRate * 2) }

  public func abort() async {
    await transcriber?.abort()
  }

  private func batch() async throws -> TranscriptResult {
    let seconds = Double(audioMs) / 1000
    return try await service.batch(wav: WAV.wrap(audio, sampleRate: sampleRate), request(settings.batchModel), timeout: 20 + seconds / 4)
  }

  public func finish() async throws -> TranscriptOutcome {
    let audioMs = self.audioMs
    let finishTimeout = service.finishTimeout(audioMs: audioMs)

    // Batch first: batch mode, or hybrid with audio that isn't too long.
    // Meanwhile the streaming transcription finishes in parallel as a backup.
    guard let transcriber, !(settings.mode == .hybrid && audioMs <= settings.batchMaxAudioMs) else {
      let backup = transcriber.map { streaming in
        Task { try await streaming.finish(timeout: finishTimeout) }
      }
      do {
        let result = try await batch()
        if let transcriber { await transcriber.abort() }
        backup?.cancel()
        return TranscriptOutcome(text: result.text, path: .batch, model: settings.batchModel)
      } catch {
        guard let backup, let transcriber else { throw error }
        let warning = errorMessage(error)
        do {
          let result = try await backup.value
          upstreamConnectMs = await transcriber.connectMs
          return TranscriptOutcome(text: result.text, path: .realtimeFallback, model: settings.realtimeModel, warning: warning)
        } catch {
          throw EngineError("\(warning); \(errorMessage(error))")
        }
      }
    }

    // Streaming first (realtime mode, or hybrid with long audio); batch if it fails.
    let warning: String
    do {
      let result = try await transcriber.finish(timeout: finishTimeout)
      upstreamConnectMs = await transcriber.connectMs
      if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audioMs < 1_500 {
        return TranscriptOutcome(text: result.text, path: .realtime, model: settings.realtimeModel)
      }
      warning = "realtime: empty transcript"
    } catch {
      warning = errorMessage(error)
    }
    do {
      let result = try await batch()
      return TranscriptOutcome(text: result.text, path: .batchFallback, model: settings.batchModel, warning: warning)
    } catch {
      throw EngineError("\(warning); \(errorMessage(error))")
    }
  }
}

// MARK: - A whole dictation

/// What's around the cursor when the key is pressed.
public struct DictationContext: Sendable, Equatable {
  public static let maxTextBefore = 1_000
  public static let maxScreenText = 2_000

  public var bundleId: String?
  public var appName: String?
  public var windowTitle: String?
  public var selectedText: String?
  public var insertion: Insertion
  /// What the field already holds before the cursor (the email or reply written so far).
  public var textBefore: String?
  /// Text on screen around the field: the conversation, the recipient, the subject.
  public var screenText: String?

  public init(
    bundleId: String? = nil, appName: String? = nil, windowTitle: String? = nil, selectedText: String? = nil, insertion: Insertion = .start,
    textBefore: String? = nil, screenText: String? = nil
  ) {
    self.bundleId = bundleId
    self.appName = appName
    self.windowTitle = windowTitle
    self.selectedText = selectedText.map { String($0.prefix(20_000)) }
    self.insertion = insertion
    self.textBefore = Self.clip(textBefore, Self.maxTextBefore)
    self.screenText = Self.clip(screenText, Self.maxScreenText)
  }

  /// The last `limit` characters, or nil when there's nothing.
  public static func clip(_ text: String?, _ limit: Int) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return String(text.suffix(limit))
  }
}

public struct DictationRequest: Sendable {
  public var mode: DictationMode
  public var context: DictationContext
  /// Two-letter code, or nil for automatic detection.
  public var language: String?
  public var vocabulary: [VocabularyEntry]
  /// Custom style per category raw value.
  public var styles: [String: String]
  /// The user's apps and websites assigned to a category.
  public var appRules: [AppRule]
  public var userName: String
  public var organization: String?
  /// Stable per-user key for prompt caching (no personal data).
  public var cacheKey: String
  public var scribeHistory: [ChatMessage]

  public init(
    mode: DictationMode, context: DictationContext, language: String?, vocabulary: [VocabularyEntry], styles: [String: String] = [:],
    appRules: [AppRule] = [], userName: String = "", organization: String? = nil, cacheKey: String, scribeHistory: [ChatMessage] = []
  ) {
    self.mode = mode
    self.context = context
    self.language = language
    self.vocabulary = vocabulary
    self.styles = styles
    self.appRules = appRules
    self.userName = userName
    self.organization = organization
    self.cacheKey = cacheKey
    self.scribeHistory = scribeHistory
  }
}

public struct DictationServices: Sendable {
  public var transcription: TranscriptionService
  public var cleanup: ChatService
  public var scribe: ChatService

  public init(transcription: TranscriptionService, cleanup: ChatService, scribe: ChatService) {
    self.transcription = transcription
    self.cleanup = cleanup
    self.scribe = scribe
  }
}

public struct DictationOutput: Sendable, Equatable {
  public enum Processing: String, Codable, Sendable {
    /// `scribeFallback`: Scribe didn't answer, so the text is the transcript, tidied as `fastFallback`.
    case fast, llm, fastFallback = "fast_fallback", scribe, scribeFallback = "scribe_fallback", empty
  }

  public var mode: DictationMode
  public var text: String
  public var raw: String
  public var category: AppCategory
  public var transcription: TranscriptionPath
  public var processing: Processing
  public var transcriptionModel: String?
  public var processingModel: String?
  /// Milliseconds: audioMs, upstreamConnectMs, transcribeMs, cleanupTtftMs, cleanupMs,
  /// scribeTtftMs, scribeMs, pipelineMs.
  public var timings: [String: Double]
  public var warnings: [String]
  public var audioMs: Int
  public var words: Int
  /// Dictionary entries whose spelling appears in the text.
  public var termsUsed: [String]
  /// The cleanup answer a guard rejected (for the bench; the app never logs it).
  public var discardedCleanup: String? = nil
}

public enum DictationError: Error, LocalizedError, Equatable {
  case transcriptionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .transcriptionFailed(let message): "Transcription failed: \(message)"
    }
  }
}

/// One dictation or Scribe request, from the first audio chunk to the final text.
public actor DictationRun {
  private var request: DictationRequest
  private let settings: PipelineSettings
  private let services: DictationServices
  private let now: EngineClock
  private let onScribeDelta: (@Sendable (String) -> Void)?
  private let transcription: TranscriptionRun
  private var category: AppCategory
  private var mode: DictationMode
  private var cancelled = false
  private var timings: [String: Double] = [:]
  /// The transcript, once the transcription is done: kept if what follows fails.
  private var transcript: Transcript?

  private struct Transcript {
    var raw: String
    var path: TranscriptionPath
    var model: String?
    var audioMs: Int
    var warnings: [String]
  }

  public static func sampleRate(for settings: PipelineSettings) -> Int {
    settings.transcription.provider.sampleRate
  }

  public init(
    request: DictationRequest, settings: PipelineSettings, services: DictationServices,
    now: @escaping EngineClock = EngineClocks.monotonic, onScribeDelta: (@Sendable (String) -> Void)? = nil
  ) {
    self.request = request
    self.settings = settings
    self.services = services
    self.now = now
    self.onScribeDelta = onScribeDelta
    self.mode = request.mode
    self.category = Categories.categorize(bundleId: request.context.bundleId, windowTitle: request.context.windowTitle, rules: request.appRules)
    self.transcription = TranscriptionRun(
      service: services.transcription, settings: settings.transcription, language: request.language,
      vocabulary: Vocabulary.bias(request.vocabulary), sampleRate: Self.sampleRate(for: settings))
  }

  public var appCategory: AppCategory { category }

  /// The context is read from Accessibility after the key press, while audio already flows.
  public func setContext(_ context: DictationContext) async {
    request.context = context
    category = Categories.categorize(bundleId: context.bundleId, windowTitle: context.windowTitle, rules: request.appRules)
    await transcription.setPreviousText(context.textBefore)
  }

  /// Names read on screen join the transcription's vocabulary (before `start`).
  public func addVocabulary(_ terms: [String]) async {
    await transcription.addTerms(terms)
  }

  /// Opens the streaming transcription (if the mode uses it).
  public func start(onText: (@Sendable (String) -> Void)? = nil) async {
    await transcription.start(onText: onText)
  }

  public func append(_ pcm: Data) async throws {
    guard !cancelled else { return }
    try await transcription.append(pcm)
  }

  public func cancel() async {
    cancelled = true
    await transcription.abort()
  }

  /// Seconds the app waits after the key is released: a margin over the cleanup's or Scribe's
  /// own limit for that much speech (about 20 characters a second), plus time for the
  /// transcription. Whichever runs out first, the transcript is kept (`recover`).
  public static func deadline(mode: DictationMode, audioMs: Int) -> Double {
    let seconds = Double(max(0, audioMs)) / 1000
    let chars = Int(seconds * 20)
    let processing = mode == .scribe ? 15 + Scribe.timeout(chars: chars) : 17 + Cleanup.timeout(chars: chars)
    return processing + seconds / 4
  }

  /// When the app stops waiting: the transcript, if it's there, as the text (as when Scribe or
  /// the cleanup fails), and the run ends; nil if the transcription isn't done.
  public func recover(_ reason: String) async -> DictationOutput? {
    cancelled = true
    await transcription.abort()
    guard let transcript, !transcript.raw.isEmpty else { return nil }
    return fallback(transcript, reason: reason)
  }

  /// The transcript, tidied without a model, instead of the cleanup or Scribe.
  private func fallback(_ transcript: Transcript, reason: String) -> DictationOutput {
    let text = Cleanup.fastClean(transcript.raw, entries: request.vocabulary, category: category, insertion: request.context.insertion)
    let step = mode == .scribe ? "scribe" : "cleanup"
    return DictationOutput(
      mode: mode, text: text, raw: transcript.raw, category: category, transcription: transcript.path,
      processing: mode == .scribe ? .scribeFallback : .fastFallback, transcriptionModel: transcript.model, processingModel: nil,
      timings: timings, warnings: transcript.warnings + ["\(step): \(reason)"], audioMs: transcript.audioMs,
      words: TextTools.wordCount(text), termsUsed: Vocabulary.termsUsed(text, request.vocabulary))
  }

  /// Ends the audio and produces the final text. `mode` overrides the starting one
  /// (Ctrl pressed after Fn turns a dictation into Scribe).
  public func finish(mode override: DictationMode? = nil) async throws -> DictationOutput {
    if let override { mode = override }
    let endedAt = now()
    let audioMs = await transcription.audioMs
    timings["audioMs"] = Double(audioMs)
    var warnings: [String] = []
    var discardedCleanup: String?

    var raw = ""
    var path = TranscriptionPath.none
    var transcriptionModel: String?
    if audioMs >= TranscriptionRun.minAudioMs {
      do {
        let outcome = try await transcription.finish()
        raw = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        path = outcome.path
        transcriptionModel = outcome.model
        if let warning = outcome.warning { warnings.append(warning) }
      } catch {
        throw DictationError.transcriptionFailed(errorMessage(error))
      }
    } else {
      await transcription.abort()
    }
    if let connect = await transcription.upstreamConnectMs { timings["upstreamConnectMs"] = connect }
    timings["transcribeMs"] = now() - endedAt
    if cancelled { throw CancellationError() }
    let transcript = Transcript(raw: raw, path: path, model: transcriptionModel, audioMs: audioMs, warnings: warnings)
    self.transcript = transcript

    let style = Categories.style(for: category, overrides: request.styles)
    var text = ""
    var processing = DictationOutput.Processing.empty
    var processingModel: String?

    if !raw.isEmpty, mode == .dictation {
      let result = await Cleanup.run(
        Cleanup.Request(
          raw: raw, entries: request.vocabulary, category: category, style: style, appName: request.context.appName,
          insertion: request.context.insertion, cacheKey: request.cacheKey, settings: settings.cleanup,
          fastPathMaxWords: settings.fastPathMaxWords, textBefore: request.context.textBefore, screenText: request.context.screenText),
        chat: services.cleanup, now: now)
      text = result.text
      processing = DictationOutput.Processing(rawValue: result.path.rawValue) ?? .fastFallback
      processingModel = result.model
      if let ttft = result.ttftMs { timings["cleanupTtftMs"] = ttft }
      timings["cleanupMs"] = result.ms
      if let error = result.error { warnings.append("cleanup: \(error)") }
      discardedCleanup = result.discarded
    } else if !raw.isEmpty, mode == .scribe {
      let input = Prompts.ScribeInput(
        userName: request.userName, organization: request.organization, appName: request.context.appName,
        windowTitle: request.context.windowTitle, category: category, style: style,
        dictionary: Vocabulary.promptList(request.vocabulary), instruction: raw, selectedText: request.context.selectedText,
        history: Prompts.sanitizeHistory(request.scribeHistory), textBefore: request.context.textBefore,
        screenText: request.context.screenText)
      let scribeStarted = now()
      do {
        let result = try await Scribe.run(
          input, entries: request.vocabulary, settings: settings.scribe, chat: services.scribe, onDelta: onScribeDelta)
        text = result.text
        processing = .scribe
        processingModel = result.model
        if let ttft = result.ttftMs { timings["scribeTtftMs"] = ttft }
        timings["scribeMs"] = result.ms
      } catch {
        // What was dictated is never lost: without Scribe, the transcript goes in.
        if cancelled { throw CancellationError() }
        timings["scribeMs"] = now() - scribeStarted
        timings["pipelineMs"] = now() - endedAt
        return fallback(transcript, reason: errorMessage(error))
      }
    }
    if cancelled { throw CancellationError() }
    timings["pipelineMs"] = now() - endedAt

    return DictationOutput(
      mode: mode, text: text, raw: raw, category: category, transcription: path, processing: processing,
      transcriptionModel: transcriptionModel, processingModel: processingModel, timings: timings, warnings: warnings,
      audioMs: audioMs, words: TextTools.wordCount(text), termsUsed: Vocabulary.termsUsed(text, request.vocabulary),
      discardedCleanup: discardedCleanup)
  }
}
