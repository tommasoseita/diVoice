import AppKit
import Carbon.HIToolbox
import DiVoiceCore
import DiVoiceEngine

/// Runs a dictation: key → microphone and engine → text → insertion → history.
final class DictationController {
  var onRecordingChange: ((Bool) -> Void)?
  var onNeedsSetup: (() -> Void)?
  /// Called with each finished dictation (for the statistics).
  var onDictation: ((DictationOutput) -> Void)?

  private let settings: AppSettings
  private let overlay: OverlayController
  private let history: HistoryStore
  private let audio = AudioCapture()
  private let inserter = Inserter()
  private let corrections = CorrectionWatcher()

  private final class Session {
    let id: UUID
    var mode: DictationMode
    var timeline: DictationTimeline
    let run: DictationRun
    /// The organization's connection, when dictating through its server.
    let relay: RelayConnection?
    /// The cleanup's model, also for learning from corrections at the end of the session.
    var cleanupChat: ChatService?
    var cleanupSettings: ChatSettings?
    /// Audio frames in order, consumed by one task that feeds the engine.
    let frames: AsyncStream<Data>
    let framesContinuation: AsyncStream<Data>.Continuation
    var feeder: Task<Void, Never>?
    /// Accessibility read of the focused app, started at the key press; it returns the names on screen.
    var contextTask: Task<[String], Never>?
    var context: CapturedContext?
    var finished = false
    var timeout: DispatchWorkItem?
    /// From the release to the final text: cancelled when the app stops waiting.
    var processing: Task<Void, Never>?
    /// Hands-free: the stop just before the 10-minute limit.
    var lockLimit: DispatchWorkItem?

    init(id: UUID, mode: DictationMode, pressNs: UInt64, run: DictationRun, relay: RelayConnection?) {
      self.id = id
      self.mode = mode
      timeline = DictationTimeline(pressNs: pressNs)
      self.run = run
      self.relay = relay
      (frames, framesContinuation) = AsyncStream.makeStream(of: Data.self)
    }
  }

  private var recording: Session?
  private var inFlight: [UUID: Session] = [:]
  private var lastLevelNs: UInt64 = 0
  /// Stable per-install key for the providers' prompt cache (no personal data).
  private lazy var cacheKey: String = {
    if let key = UserDefaults.standard.string(forKey: "cacheKey") { return key }
    let key = UUID().uuidString.lowercased()
    UserDefaults.standard.set(key, forKey: "cacheKey")
    return key
  }()

  init(settings: AppSettings, overlay: OverlayController, history: HistoryStore) {
    self.settings = settings
    self.overlay = overlay
    self.history = history
    corrections.onCorrection = { correction, category in
      Task { @MainActor in LearningStore.shared.record(correction, category: category) }
    }
    prepareMicrophone()
  }

  /// Prepares the audio engine ahead of time (without turning the microphone on).
  func prepareMicrophone() {
    guard Permissions.microphone == .authorized else { return }
    audio.prepare(deviceUID: settings.microphoneUID, sampleRate: DictationRun.sampleRate(for: EngineFactory.activePipeline(settings)))
  }

  func handle(_ action: HotkeyAction) {
    switch action {
    case let .start(mode, timestamp):
      start(mode: mode, pressNs: timestamp)
    case let .modeChanged(mode):
      recording?.mode = mode
      overlay.setMode(mode)
    case let .lock(mode, key):
      lock(mode, key: key)
    case let .stop(mode, timestamp, _):
      stop(mode: mode, releaseNs: timestamp)
    case let .cancel(reason):
      cancel(reason)
    }
  }

  /// Inserts the last dictation again (menu item).
  func pasteLast() {
    guard let last = history.last else { return }
    inserter.restoreClipboard = settings.restoreClipboard
    inserter.insert(last.text, secureInput: IsSecureEventInputEnabled()) { [weak self] outcome in
      if outcome.manual { self?.overlay.showInfo(String(localized: "Text copied: press ⌘V")) }
    }
  }

  // MARK: Lifecycle

  private func start(mode: DictationMode, pressNs: UInt64) {
    guard recording == nil else { return }
    // A new dictation: the user moved on from the last one.
    corrections.finish()
    let id = UUID()
    let engine: EngineFactory.Dictation
    do {
      engine = try EngineFactory.dictation(settings, sessionId: id.uuidString.lowercased())
    } catch {
      overlay.showError(error.localizedDescription)
      onNeedsSetup?()
      return
    }
    let pipeline = engine.pipeline
    guard Permissions.microphone == .authorized else {
      Task { await engine.relay?.close() }
      overlay.showError(String(localized: "diVoice needs microphone access"))
      onNeedsSetup?()
      return
    }

    let store = OrgStore.shared
    let request = DictationRequest(
      mode: mode, context: DictationContext(), language: TextTools.normalizeLanguage(settings.language),
      vocabulary: store.vocabulary(personal: VocabularyStore.shared.entries),
      styles: settings.style.styles(learned: MainActor.assumeIsolated { LearningStore.shared.learned }),
      appRules: settings.style.rules, userName: NSFullUserName(),
      organization: store.membership?.orgName, cacheKey: cacheKey)
    // Scribe's text goes straight into the app when it's complete: the overlay doesn't show it.
    let run = DictationRun(request: request, settings: pipeline, services: engine.services)
    let session = Session(id: id, mode: mode, pressNs: pressNs, run: run, relay: engine.relay)
    session.cleanupChat = engine.services.cleanup
    session.cleanupSettings = pipeline.cleanup

    // The context is read off the main thread: Accessibility reads can be slow.
    let app = NSWorkspace.shared.frontmostApplication
    let readScreen = settings.useScreenContext
    let contextTask = Task.detached(priority: .userInitiated) { () -> [String] in
      let context = FocusedContextReader.capture(app: app, readScreen: readScreen)
      await MainActor.run { session.context = context }
      await run.setContext(context.context)
      return context.screenNames
    }
    session.contextTask = contextTask
    session.feeder = Task {
      // The names on screen join the vocabulary: the transcription waits for them a quarter of a
      // second at most, while the audio piles up in the stream.
      if let names = await Self.value(of: contextTask, within: 0.25), !names.isEmpty { await run.addVocabulary(names) }
      await run.start()
      for await frame in session.frames {
        try? await run.append(frame)
      }
    }

    let continuation = session.framesContinuation
    audio.onFrame = { frame in continuation.yield(frame) }
    audio.onLevel = { [weak self] level in self?.level(level) }
    // The start sound plays when the microphone is really on: it's the cue to speak.
    audio.onFirstBuffer = { [weak self, weak session] ns in
      DispatchQueue.main.async {
        guard let self, let session, self.recording === session else { return }
        session.timeline.firstAudioNs = ns
        Sounds.start(self.settings)
      }
    }

    do {
      try audio.start(deviceUID: settings.microphoneUID, sampleRate: DictationRun.sampleRate(for: pipeline))
    } catch {
      session.framesContinuation.finish()
      session.feeder?.cancel()
      Task { await run.cancel() }
      overlay.showError(String(localized: "Microphone not available: \(error.localizedDescription)"))
      return
    }
    recording = session
    overlay.showRecording(mode: mode)
    onRecordingChange?(true)
  }

  /// The task's result if it arrives in time, otherwise nil (the task goes on).
  private static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
    let once = OnceFlag()
    return await withCheckedContinuation { continuation in
      Task {
        let value = await task.value
        if once.claim() { continuation.resume(returning: value) }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if once.claim() { continuation.resume(returning: nil) }
      }
    }
  }

  /// A double tap: the dictation goes on hands-free until the key is pressed again.
  private func lock(_ mode: DictationMode, key: String) {
    guard let session = recording else { return }
    session.mode = mode
    overlay.setMode(mode)
    overlay.setLocked(key: key)
    Sounds.start(settings)
    appLog.notice("Hands-free \(mode.rawValue, privacy: .public) with \(key, privacy: .public)")
    // Recordings stop at 10 minutes: end it just before, as if the key had been pressed.
    let limit = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session, self.recording === session else { return }
      self.stop(mode: session.mode, releaseNs: MonotonicClock.nowNs())
    }
    session.lockLimit = limit
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxHandsFreeSeconds, execute: limit)
  }

  /// Just under the engine's 10 minutes.
  static let maxHandsFreeSeconds: TimeInterval = 590

  private func stop(mode: DictationMode, releaseNs: UInt64) {
    guard let session = recording else { return }
    session.lockLimit?.cancel()
    recording = nil
    session.mode = mode
    session.timeline.releaseNs = releaseNs
    if let rest = audio.stop() { session.framesContinuation.yield(rest) }
    session.framesContinuation.finish()
    inFlight[session.id] = session
    overlay.showProcessing(mode: mode)
    onRecordingChange?(false)
    Sounds.stop(settings)

    // The engine has its own limits, which keep the transcript: this one is for anything that hangs.
    // It grows with the audio, so a long dictation has time for its transcription and Scribe.
    let audioMs = session.timeline.firstAudioNs.map { releaseNs > $0 ? Int((releaseNs - $0) / 1_000_000) : 0 } ?? 0
    let timeout = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session, !session.finished else { return }
      let message = session.relay == nil
        ? String(localized: "The provider did not answer in time") : String(localized: "The organization's server did not answer in time")
      Task { @MainActor [weak self] in
        // The transcript, if it's done, is still delivered.
        let output = await session.run.recover("no answer in time")
        session.processing?.cancel()
        if let output { self?.deliver(output, for: session) } else { self?.fail(session, message) }
      }
    }
    session.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + DictationRun.deadline(mode: mode, audioMs: audioMs), execute: timeout)

    session.processing = Task { @MainActor [weak self] in
      // All the audio and the context first, then the end.
      await session.feeder?.value
      _ = await session.contextTask?.value
      session.timeline.endSentNs = MonotonicClock.nowNs()
      do {
        let output = try await session.run.finish(mode: mode)
        self?.deliver(output, for: session)
      } catch is CancellationError {
        return
      } catch {
        self?.fail(session, error.localizedDescription)
      }
    }
  }

  private func cancel(_ reason: CancelReason) {
    guard let session = recording else { return }
    recording = nil
    session.lockLimit?.cancel()
    _ = audio.stop()
    session.finished = true
    session.framesContinuation.finish()
    Task {
      await session.run.cancel()
      await session.relay?.close()
    }
    onRecordingChange?(false)
    if reason == .escape { overlay.showInfo(String(localized: "Dictation cancelled")) } else { overlay.hide() }
  }

  // MARK: Result

  private func deliver(_ output: DictationOutput, for session: Session) {
    guard !session.finished else { return }
    finish(session)
    session.timeline.resultNs = MonotonicClock.nowNs()
    guard !output.text.isEmpty else {
      Task { await session.relay?.close() }
      overlay.showInfo(String(localized: "I didn't hear anything"))
      return
    }
    let unanswered = output.processing == .scribeFallback
    // Scribe was to rewrite the selection: the instruction mustn't replace it. It stays in History.
    if unanswered, session.context?.context.selectedText?.isEmpty == false {
      overlay.showError(String(localized: "Scribe didn't answer. What you said is in History."))
      record(session, output)
      return
    }
    let text = SmartSpacing.adjust(output.text, textBefore: session.context?.textBefore)
    inserter.restoreClipboard = settings.restoreClipboard
    inserter.insert(text, secureInput: session.context?.secureInput ?? false) { [weak self] outcome in
      guard let self else { return }
      session.timeline.pastePostedNs = outcome.pastePostedNs
      session.timeline.insertedNs = outcome.insertedNs
      // The text in the app is the confirmation: the overlay just goes away.
      if outcome.manual {
        self.overlay.showInfo(String(localized: "Text copied: press ⌘V"))
      } else if unanswered {
        self.overlay.showInfo(String(localized: "Scribe didn't answer: I inserted your dictation without rewriting it"), seconds: 5)
      } else {
        self.overlay.hide()
      }
      // Edits to a transcript that Scribe didn't rewrite say nothing about the user's style.
      if !outcome.manual, !unanswered, self.settings.learnFromCorrections, let field = session.context?.field, let pid = session.context?.pid {
        self.corrections.watch(field: field, pid: pid, inserted: text, category: output.category)
      }
      self.record(session, output)
    }
  }

  private func record(_ session: Session, _ output: DictationOutput) {
    history.add(HistoryEntry(
      id: session.id.uuidString.lowercased(),
      date: Date(),
      mode: output.mode.rawValue,
      appName: session.context?.context.appName,
      category: output.category.rawValue,
      text: output.text,
      raw: output.raw,
      transcription: output.transcription.rawValue,
      cleanup: output.processing.rawValue,
      totalMs: session.timeline.totalMs,
      // Counts only: how much context the screen gave, never its text.
      clientTimings: session.timeline.metrics.merging(
        ["screenChars": Double(session.context?.screenChars ?? 0), "screenMs": session.context?.screenMs ?? 0]) { a, _ in a },
      pipelineTimings: output.timings
    ))
    VocabularyStore.shared.recordUsage(output.termsUsed)
    // Only paths and timings, never the text.
    let timings = output.timings.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value))" }.joined(separator: " ")
    appLog.notice("""
    Dictation \(output.mode.rawValue, privacy: .public): \(output.transcription.rawValue, privacy: .public)/\(output.processing.rawValue, privacy: .public), \
    total \(Int(session.timeline.totalMs ?? -1)) ms, \(timings, privacy: .public)\(output.warnings.isEmpty ? "" : " warnings: " + output.warnings.joined(separator: " | "), privacy: .public)
    """)
    onDictation?(output)
    sendStats(session, output)
  }

  /// The organization's statistics (counts only), then what's waiting to be learned from earlier
  /// corrections, with this dictation's cleanup model and connection; then the connection closes.
  private func sendStats(_ session: Session, _ output: DictationOutput) {
    let relay = session.relay
    let stats = RelayStats(
      mode: output.mode.rawValue, category: output.category.rawValue, words: output.words,
      localDay: DictationStats.dayKey(Date()), typingWPM: settings.typingWPM, cleanupPath: output.processing.rawValue,
      timings: session.timeline.metrics)
    let learn = settings.learnFromCorrections
    Task { @MainActor [weak self] in
      if let relay { await relay.sendStats(stats) }
      if learn, let chat = session.cleanupChat, let chatSettings = session.cleanupSettings {
        // The server allows four chats per session: this dictation used one.
        let terms = await LearningStore.shared.runPending(chat: chat, settings: chatSettings, limit: 2)
        if let term = terms.first, let self, self.recording == nil {
          self.overlay.showInfo(String(localized: "Added to the dictionary: \(term)"))
        }
      }
      guard let relay else { return }
      await relay.close()
      // The server records the counts once the connection has closed: give it a moment.
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      await MainActor.run { NotificationCenter.default.post(name: .diVoiceDictationRecorded, object: nil) }
    }
  }

  private func finish(_ session: Session) {
    session.finished = true
    session.timeout?.cancel()
    inFlight[session.id] = nil
  }

  private func fail(_ session: Session, _ message: String) {
    guard !session.finished else { return }
    if recording === session {
      recording = nil
      _ = audio.stop()
      session.framesContinuation.finish()
      onRecordingChange?(false)
    }
    finish(session)
    Task { await session.relay?.close() }
    appLog.error("Dictation failed: \(message, privacy: .public)")
    overlay.showError(message)
  }

  private func level(_ value: Float) {
    // Audio queue: at most ~25 updates per second towards the interface.
    let now = MonotonicClock.nowNs()
    guard now - lastLevelNs > 40_000_000 else { return }
    lastLevelNs = now
    DispatchQueue.main.async { [weak self] in self?.overlay.pushLevel(value) }
  }
}

enum Sounds {
  static func start(_ settings: AppSettings) {
    play("Tink", settings)
  }

  static func stop(_ settings: AppSettings) {
    play("Pop", settings)
  }

  private static func play(_ name: String, _ settings: AppSettings) {
    guard settings.playSounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
    sound.volume = 0.25
    sound.play()
  }
}

/// True the first time only, from any thread.
private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func claim() -> Bool {
    lock.withLock {
      defer { done = true }
      return !done
    }
  }
}
