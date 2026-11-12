import DiVoiceCore
import Foundation
import Testing

@testable import DiVoiceEngine

private let vocabulary = [entry("Acme", aliases: ["akme"]), entry("Zentrix", aliases: ["centrix"])]
private let longRaw = "ehm allora domani presentiamo centrix a akme e poi ehm facciamo il punto con tutti"
private let clean = "Domani presentiamo Zentrix a Acme e poi facciamo il punto con tutti."

private struct Harness {
  let transcription: FakeTranscription
  let http: FakeHTTP
  let run: DictationRun
  let deltas: Locked<[String]>
}

private func harness(
  mode: TranscriptionMode = .realtime,
  realtime: Result<TranscriptResult, Error> = .success(TranscriptResult(text: "")),
  batch: Result<TranscriptResult, Error> = .success(TranscriptResult(text: "")),
  chat: [String] = ["ok"],
  dictationMode: DictationMode = .dictation,
  context: DictationContext = DictationContext(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "general"),
  fastPathMaxWords: Int = 12,
  batchMaxAudioMs: Int = 25_000,
  chatHTTP: HTTPClient? = nil
) -> Harness {
  let transcription = FakeTranscription(realtime: realtime, batch: batch)
  let http = FakeHTTP(pieces: chat)
  var settings = PipelineSettings.defaults(.mistral)
  settings.transcription.mode = mode
  settings.transcription.batchMaxAudioMs = batchMaxAudioMs
  settings.fastPathMaxWords = fastPathMaxWords
  let chatClient = ChatCompletionsClient(provider: .mistral, endpoint: .direct(.mistral, apiKey: "k"), http: chatHTTP ?? http)
  let deltas = Locked<[String]>([])
  let run = DictationRun(
    request: DictationRequest(
      mode: dictationMode, context: context, language: "it", vocabulary: vocabulary, userName: "Ada Lovelace", cacheKey: "user-1"),
    settings: settings,
    services: DictationServices(transcription: transcription, cleanup: chatClient, scribe: chatClient),
    onScribeDelta: { delta in deltas.withValue { $0.append(delta) } })
  return Harness(transcription: transcription, http: http, run: run, deltas: deltas)
}

private func record(_ h: Harness, ms: Int, mode: DictationMode? = nil) async throws -> DictationOutput {
  await h.run.start()
  try await h.run.append(silence(ms: ms / 2))
  try await h.run.append(silence(ms: ms - ms / 2))
  return try await h.run.finish(mode: mode)
}

/// A chat that doesn't answer until it's cancelled.
private final class SilentHTTP: HTTPClient, @unchecked Sendable {
  private let called = Locked(false)
  var asked: Bool { called.current }

  func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw EngineError("not used")
  }

  func lines(_ request: URLRequest, label: String, _ onLine: (String) throws -> Void) async throws {
    called.withValue { $0 = true }
    try await Task.sleep(nanoseconds: 600_000_000_000)
  }
}

@Suite struct DictationTests {
  @Test func realtimeForwardsAudioCleansAndReportsTimings() async throws {
    let h = harness(realtime: .success(TranscriptResult(text: longRaw)), chat: [clean])
    let partials = Locked<[String]>([])
    await h.run.start { text in partials.withValue { $0.append(text) } }
    try await h.run.append(silence(ms: 1000))
    try await h.run.append(silence(ms: 1000))
    let output = try await h.run.finish()

    let streaming = try #require(h.transcription.streamingRequest)
    #expect(streaming.vocabulary == ["Acme", "Zentrix"])
    #expect(streaming.language == "it")
    #expect(streaming.delayMs == 480)
    #expect(streaming.sampleRate == 16_000)
    #expect(await h.transcription.transcriber?.audioBytes == 64_000)
    #expect(partials.current.first == "testo parziale")

    #expect(output.mode == .dictation)
    #expect(output.text == clean)
    #expect(output.raw == longRaw)
    #expect(output.category == .workChat)
    #expect(output.transcription == .realtime)
    #expect(output.processing == .llm)
    #expect(output.warnings.isEmpty)
    #expect(output.audioMs == 2000)
    #expect(output.timings["audioMs"] == 2000)
    #expect(output.timings["upstreamConnectMs"] == 7)
    for key in ["transcribeMs", "cleanupMs", "pipelineMs"] { #expect(output.timings[key] != nil) }
    #expect(h.transcription.batchCalls.isEmpty)
    #expect(output.termsUsed.sorted() == ["id-acme", "id-zentrix"])
    #expect(output.words == TextTools.wordCount(clean))
  }

  @Test func fallsBackToBatchWhenRealtimeFails() async throws {
    let h = harness(realtime: .failure(EngineError("realtime: connection closed (1011)")), batch: .success(TranscriptResult(text: longRaw)), chat: [clean])
    let output = try await record(h, ms: 2000)
    #expect(output.transcription == .batchFallback)
    #expect(output.text == clean)
    #expect(output.warnings == ["realtime: connection closed (1011)"])
    let (wav, request) = try #require(h.transcription.batchCalls.first)
    #expect(request.model == "voxtral-mini-transcribe-3-0")
    #expect(request.vocabulary == ["Acme", "Zentrix"])
    #expect(request.language == "it")
    #expect(wav.count == 44 + 64_000)
    #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
  }

  @Test func fallsBackToBatchWhenRealtimeIsEmptyOnLongAudio() async throws {
    let h = harness(realtime: .success(TranscriptResult(text: "  ")), batch: .success(TranscriptResult(text: "ci vediamo domani")))
    let output = try await record(h, ms: 2000)
    #expect(output.transcription == .batchFallback)
    #expect(output.processing == .fast)
    #expect(output.text == "Ci vediamo domani")
  }

  @Test func batchModeDoesNotOpenTheStream() async throws {
    let h = harness(mode: .batch, batch: .success(TranscriptResult(text: "ci vediamo domani")))
    let output = try await record(h, ms: 800)
    #expect(h.transcription.transcriber == nil)
    #expect(output.transcription == .batch)
    #expect(output.processing == .fast)
  }

  @Test func tooShortAudioGivesAnEmptyResultWithoutCalls() async throws {
    let h = harness(realtime: .success(TranscriptResult(text: "ciao")))
    let output = try await record(h, ms: 100)
    #expect(output.text.isEmpty)
    #expect(output.processing == .empty)
    #expect(output.transcription == TranscriptionPath.none)
    #expect(await h.transcription.transcriber?.aborted == true)
    #expect(h.http.requests.isEmpty)
  }

  @Test func failsWhenBothTranscriptionsFail() async throws {
    let h = harness(realtime: .failure(EngineError("timeout")), batch: .failure(EngineError("batch: HTTP 503")))
    await #expect(throws: DictationError.transcriptionFailed("timeout; batch: HTTP 503")) { try await record(h, ms: 1000) }
  }

  @Test func scribeStreamsDeltasAndReturnsTheFinalText() async throws {
    let h = harness(
      realtime: .success(TranscriptResult(text: "scrivi a Marco che la call slitta a giovedì")),
      chat: ["Ciao Marco, ", "la call slitta a giovedì."], dictationMode: .scribe,
      context: DictationContext(bundleId: "com.apple.mail", appName: "Mail", selectedText: "testo vecchio"))
    let output = try await record(h, ms: 1500)
    #expect(h.deltas.current == ["Ciao Marco, ", "la call slitta a giovedì."])
    #expect(output.mode == .scribe)
    #expect(output.processing == .scribe)
    #expect(output.category == .email)
    #expect(output.text == "Ciao Marco, la call slitta a giovedì.")
    let body = try #require(h.http.requests.first).json
    #expect(body["model"] as? String == "mistral-medium-2604")
    // Medium answers without reasoning: no parameter, no extra room.
    #expect(body["reasoning_effort"] == nil)
    #expect(body["max_tokens"] as? Int == 1_500)
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages[0]["content"]?.contains("Ada Lovelace") == true)
    #expect(messages[0]["content"]?.contains("works at") == false)
    #expect(messages.last?["content"]?.contains("Selected text:\ntesto vecchio") == true)
  }

  @Test func theModeGivenAtTheEndWins() async throws {
    let h = harness(realtime: .success(TranscriptResult(text: "scrivi a Marco che arrivo tardi")), chat: ["Ciao Marco, arrivo tardi."])
    let output = try await record(h, ms: 1500, mode: .scribe)
    #expect(output.mode == .scribe)
    #expect(output.processing == .scribe)
  }

  @Test func midSentenceUsesTheModelEvenForShortText() async throws {
    let h = harness(
      realtime: .success(TranscriptResult(text: "Marco e Luca")), chat: ["Marco e Luca"],
      context: DictationContext(bundleId: "com.apple.TextEdit", insertion: .mid))
    let output = try await record(h, ms: 1000)
    #expect(output.processing == .llm)
    #expect(output.text == "Marco e Luca")
    let call = try #require(h.http.requests.first)
    let messages = try #require(call.json["messages"] as? [[String: String]])
    #expect(messages[1]["content"]?.contains("in the middle of a sentence") == true)
  }

  @Test func hybridUsesBatchForShortAudioAndClosesTheStream() async throws {
    let h = harness(
      mode: .hybrid, realtime: .success(TranscriptResult(text: "atena mandato")),
      batch: .success(TranscriptResult(text: "ho appena mandato la proposta")), chat: ["Ho appena mandato la proposta."],
      fastPathMaxWords: 0)
    let output = try await record(h, ms: 2000)
    #expect(await h.transcription.transcriber?.aborted == true)
    #expect(h.transcription.batchCalls.first?.1.vocabulary == ["Acme", "Zentrix"])
    #expect(output.transcription == .batch)
    #expect(output.raw == "ho appena mandato la proposta")
    #expect(output.processing == .llm)
    #expect(output.text == "Ho appena mandato la proposta.")
    #expect(output.transcriptionModel == "voxtral-mini-transcribe-3-0")
  }

  @Test func hybridUsesTheReadyStreamWhenBatchFails() async throws {
    let h = harness(
      mode: .hybrid, realtime: .success(TranscriptResult(text: "ci vediamo domani")), batch: .failure(EngineError("batch: HTTP 503")),
      chat: ["Ci vediamo domani."], fastPathMaxWords: 0)
    let output = try await record(h, ms: 2000)
    #expect(output.transcription == .realtimeFallback)
    #expect(output.text == "Ci vediamo domani.")
    #expect(output.transcriptionModel == "voxtral-mini-transcribe-realtime-3-0")
    #expect(output.warnings == ["batch: HTTP 503"])
  }

  @Test func hybridUsesTheStreamForLongAudio() async throws {
    let h = harness(
      mode: .hybrid, realtime: .success(TranscriptResult(text: "dettatura lunga")), batch: .success(TranscriptResult(text: "non usato")),
      chat: ["Dettatura lunga."], fastPathMaxWords: 0, batchMaxAudioMs: 1000)
    let output = try await record(h, ms: 1500)
    #expect(h.transcription.batchCalls.isEmpty)
    #expect(output.transcription == .realtime)
    #expect(output.text == "Dettatura lunga.")
  }

  @Test func hybridReportsBothCausesWhenBothFail() async throws {
    let h = harness(mode: .hybrid, realtime: .failure(EngineError("realtime: timeout")), batch: .failure(EngineError("batch: HTTP 500")))
    await #expect(throws: DictationError.transcriptionFailed("batch: HTTP 500; realtime: timeout")) { try await record(h, ms: 1000) }
  }

  @Test func cancelStopsWithoutAResult() async throws {
    let h = harness(realtime: .success(TranscriptResult(text: "ok")))
    await h.run.start()
    try await h.run.append(silence(ms: 500))
    await h.run.cancel()
    #expect(await h.transcription.transcriber?.aborted == true)
    await #expect(throws: CancellationError.self) { try await h.run.finish() }
    #expect(h.http.requests.isEmpty)
  }

  @Test func openAIUsesTwentyFourKilohertz() {
    #expect(DictationRun.sampleRate(for: .defaults(.openai)) == 24_000)
    #expect(DictationRun.sampleRate(for: .defaults(.mistral)) == 16_000)
  }
}

@Suite struct VerifierTests {
  @Test func verifiesStreamingAndBatchModels() async {
    let service = FakeTranscription(realtime: .success(TranscriptResult(text: "prova")), batch: .success(TranscriptResult(text: "prova batch")))
    let reports = await Verifier.transcription(
      .defaults(.mistral), service: service, pcm: silence(ms: 1000), language: "it", vocabulary: ["Acme"], pace: 0)
    #expect(reports.map(\.step) == [.streaming, .batch])
    #expect(reports.map(\.ok) == [true, true])
    #expect(reports[0].model == "voxtral-mini-transcribe-realtime-3-0")
    #expect(reports[0].detail == "prova")
    #expect(reports[0].connectMs == 7)
    #expect(reports[1].detail == "prova batch")
    #expect(service.batchCalls.count == 1)
  }

  @Test func reportsTranscriptionErrors() async {
    let service = FakeTranscription(batch: .failure(HTTPStatusError(label: "batch", status: 401, body: "Unauthorized")))
    var settings = TranscriptionSettings.defaults(.mistral)
    settings.mode = .batch
    let reports = await Verifier.transcription(settings, service: service, pcm: silence(ms: 1000), language: nil, vocabulary: [])
    #expect(reports.count == 1)
    #expect(reports[0].ok == false)
    #expect(reports[0].detail == "batch: HTTP 401 Unauthorized")
  }

  @Test func retriesWithoutPredictionWhenTheModelRefusesIt() async throws {
    final class RefusesPrediction: HTTPClient, @unchecked Sendable {
      let inner = FakeHTTP(pieces: ["Questa è una prova di verifica."])
      func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await inner.data(request) }
      func lines(_ request: URLRequest, label: String, _ onLine: (String) throws -> Void) async throws {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
        if body["prediction"] != nil { throw HTTPStatusError(label: label, status: 400, body: "prediction not supported") }
        try await inner.lines(request, label: label, onLine)
      }
    }
    let http = RefusesPrediction()
    let chat = ChatCompletionsClient(provider: .mistral, endpoint: .direct(.mistral, apiKey: "k"), http: http)
    let report = await Verifier.chat(.cleanupDefaults(.mistral), step: .cleanup, chat: chat)
    #expect(report.ok)
    #expect(report.predictionAccepted == false)
    #expect(report.firstTokenMs != nil)
  }
}

@Suite struct MistralGreedySamplingTests {
  @Test func temperatureZeroAlsoSendsTopPOne() async throws {
    let http = FakeHTTP(pieces: ["ok"])
    let chat = ChatCompletionsClient(provider: .mistral, endpoint: .direct(.mistral, apiKey: "k"), http: http)
    _ = try await chat.stream(ChatCall(model: "mistral-large-4-0", messages: [], temperature: 0, maxTokens: 10), timeout: 5, onDelta: nil)
    _ = try await chat.stream(ChatCall(model: "mistral-large-4-0", messages: [], temperature: 0.4, maxTokens: 10), timeout: 5, onDelta: nil)
    #expect(http.requests[0].json["top_p"] as? Int == 1)
    #expect(http.requests[1].json["top_p"] == nil)
  }

  @Test func scribeVerifyUsesTheScribeRequest() async throws {
    let http = FakeHTTP(pieces: ["Una frase di prova."])
    let chat = ChatCompletionsClient(provider: .mistral, endpoint: .direct(.mistral, apiKey: "k"), http: http)
    let report = await Verifier.chat(.scribeDefaults(.mistral), step: .scribe, chat: chat)
    #expect(report.ok)
    let body = try #require(http.requests.first).json
    #expect(body["temperature"] as? Double == 0.4)
    #expect(body["reasoning_effort"] == nil)
    #expect(body["max_tokens"] as? Int == 120)
    let system = try #require((body["messages"] as? [[String: String]])?.first?["content"])
    #expect(system.contains("You are Scribe"))
  }

  @Test func scribeRewritesFreelyButEditsASelectionClosely() {
    func input(selected: String?, history: [ChatMessage] = []) -> Prompts.ScribeInput {
      Prompts.ScribeInput(
        userName: "Ada", appName: "Slack", windowTitle: nil, category: .workChat, style: "Direct.", dictionary: "",
        instruction: "ok va bene giovedì", selectedText: selected, history: history)
    }
    let rewrite = input(selected: nil)
    #expect(Scribe.temperature(rewrite) == 0.4)
    #expect(Prompts.scribe(rewrite)[0].content.contains("Really rewrite it"))
    #expect(Scribe.temperature(input(selected: "Ci vediamo giovedì.")) == 0.2)
    #expect(Scribe.temperature(input(selected: nil, history: [ChatMessage(role: .user, content: "a"), ChatMessage(role: .assistant, content: "b")])) == 0.2)
  }

  // MARK: What was dictated is never lost

  @Test func whenScribeFailsTheTranscriptGoesIn() async throws {
    let h = harness(
      realtime: .success(TranscriptResult(text: "scrivi a centrix che la call slitta a giovedì")), dictationMode: .scribe,
      context: DictationContext(bundleId: "com.apple.mail", appName: "Mail"))
    h.http.status = 500
    let output = try await record(h, ms: 1500)
    #expect(output.mode == .scribe)
    #expect(output.processing == .scribeFallback)
    #expect(output.raw == "scrivi a centrix che la call slitta a giovedì")
    // Tidied without a model: dictionary spellings and the capital letter.
    #expect(output.text == "Scrivi a Zentrix che la call slitta a giovedì")
    #expect(output.processingModel == nil)
    #expect(output.transcriptionModel == "voxtral-mini-transcribe-realtime-3-0")
    #expect(output.warnings.count == 1)
    #expect(output.warnings.first?.hasPrefix("scribe: ") == true)
    #expect(output.timings["scribeMs"] != nil)
    #expect(output.words == 9)
  }

  @Test func theAppStoppingToWaitStillGetsTheTranscript() async throws {
    let silent = SilentHTTP()
    let h = harness(
      realtime: .success(TranscriptResult(text: "una dettatura molto lunga")), dictationMode: .scribe,
      context: DictationContext(bundleId: "com.apple.mail", appName: "Mail"), chatHTTP: silent)
    await h.run.start()
    try await h.run.append(silence(ms: 1500))
    let finishing = Task { try await h.run.finish() }
    // Scribe is writing, and won't answer.
    try await eventually { silent.asked }
    let output = try #require(await h.run.recover("no answer in time"))
    #expect(output.processing == .scribeFallback)
    #expect(output.text == "Una dettatura molto lunga")
    #expect(output.warnings == ["scribe: no answer in time"])
    // The run is over: the app cancels what was still waiting.
    finishing.cancel()
    await #expect(throws: CancellationError.self) { try await finishing.value }
  }

  @Test func aDictationStoppedWhileCleaningKeepsItsTranscriptToo() async throws {
    let silent = SilentHTTP()
    let h = harness(realtime: .success(TranscriptResult(text: longRaw)), chatHTTP: silent)
    await h.run.start()
    try await h.run.append(silence(ms: 2000))
    let finishing = Task { try await h.run.finish() }
    try await eventually { silent.asked }
    let output = try #require(await h.run.recover("no answer in time"))
    #expect(output.processing == .fastFallback)
    #expect(output.raw == longRaw)
    #expect(output.warnings == ["cleanup: no answer in time"])
    finishing.cancel()
    _ = try? await finishing.value
  }

  @Test func nothingToRecoverBeforeTheTranscript() async throws {
    let h = harness(dictationMode: .scribe)
    await h.run.start()
    try await h.run.append(silence(ms: 1500))
    #expect(await h.run.recover("no answer in time") == nil)
  }

  @Test func theAppWaitsLongerForLongDictations() {
    // A short dictation: as before, 25 seconds, 75 with Scribe.
    #expect(DictationRun.deadline(mode: .dictation, audioMs: 0) == 25)
    #expect(DictationRun.deadline(mode: .scribe, audioMs: 0) == 75)
    // Almost four minutes of Scribe: more than its own limit for that much text.
    let long = 225_000
    #expect(DictationRun.deadline(mode: .scribe, audioMs: long) > Scribe.timeout(chars: 225 * 20) + 15)
    #expect(DictationRun.deadline(mode: .dictation, audioMs: long) > Cleanup.timeout(chars: 225 * 20) + 17)
    // Hands-free at its limit: under 8 minutes.
    #expect(DictationRun.deadline(mode: .scribe, audioMs: 590_000) < 480)
  }
}
