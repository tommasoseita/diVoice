import Foundation

public enum CleanupPath: String, Codable, Sendable {
  case fast
  case llm
  case fastFallback = "fast_fallback"
}

public struct CleanupResult: Sendable, Equatable {
  public var text: String
  public var path: CleanupPath
  public var model: String?
  public var ttftMs: Double?
  public var ms: Double
  public var error: String?
  /// The model's answer when a guard rejected it: for the bench, never logged.
  public var discarded: String? = nil
}

/// Turns the raw transcript into the text the user meant to write.
public enum Cleanup {
  /// Words that need the model even in a short sentence: fillers, self-corrections
  /// and dictated punctuation.
  private static let needsModelPattern = TextTools.regex(
    "(?<![\\p{L}])("
      + [
        "e+h+m+", "u+h*m+", "e+h+", "m+h*m+", "cioè", "tipo", "anzi", "aspetta", "volevo dire", "scusa", "scusate",
        "virgola", "punto", "a capo", "nuova riga", "nuovo paragrafo", "due punti", "parentesi", "virgolette",
        "chiocciola", "u+m+", "u+h+", "erm", "i mean", "sorry", "actually", "comma", "period", "new line",
        "new paragraph", "question mark",
      ].joined(separator: "|") + ")(?![\\p{L}])",
    ignoreCase: true)
  private static let repeatedWord = TextTools.regex("(?<![\\p{L}])(\\p{L}+)\\s+\\1(?![\\p{L}])", ignoreCase: true)
  private static let answerPrefix = TextTools.regex("^(testo( pulito| finale)?|((cleaned|final) )?text|output)\\s*:\\s*", ignoreCase: true)
  private static let finalPeriod = TextTools.regex("(?<!\\.)\\.$")

  public static func needsModel(_ raw: String, fastPathMaxWords: Int) -> Bool {
    if fastPathMaxWords <= 0 { return true }
    if TextTools.wordCount(raw) > fastPathMaxWords { return true }
    return TextTools.matches(needsModelPattern, raw) || TextTools.matches(repeatedWord, raw)
  }

  /// Deterministic cleanup for short sentences and as a safety net.
  public static func fastClean(_ raw: String, entries: [VocabularyEntry], category: AppCategory, insertion: Insertion = .start) -> String {
    var text = Vocabulary.applyAliases(TextTools.collapseWhitespace(raw).trimmingCharacters(in: .whitespacesAndNewlines), entries)
    guard let first = text.first else { return text }
    // Mid-sentence the case stays: it could be a proper name.
    if insertion == .start { text = String(first).uppercased(with: Locale(identifier: "it")) + text.dropFirst() }
    if category == .personalChat {
      text = finalPeriod.stringByReplacingMatches(in: text, range: TextTools.fullRange(text), withTemplate: "")
    }
    return text
  }

  static func postProcess(_ output: String, entries: [VocabularyEntry]) -> String {
    var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    text = answerPrefix.stringByReplacingMatches(in: text, range: TextTools.fullRange(text), withTemplate: "")
    // A whole answer wrapped in quotes: drop them, unless the same quote also appears inside.
    if let first = text.first, let last = text.last, text.count >= 2, "\"“«`".contains(first), "\"”»`".contains(last) {
      let inner = text.dropFirst().dropLast()
      if !inner.contains(first) { text = inner.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return Vocabulary.applyAliases(text, entries)
  }

  /// Guards against answers that are not a cleanup (for example the model replying to the text).
  static func looksWrong(_ output: String, raw: String) -> Bool {
    let o = output.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    let r = raw.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    if o == 0 { return true }
    if Double(o) > Double(r) * 2 + 60 { return true }
    if r > 40 && Double(o) < Double(r) * 0.35 { return true }
    return looksTranslated(output, raw: raw)
  }

  /// Cleanup keeps the spoken words: a translation (which small models sometimes do
  /// despite the prompt) shares almost none of them.
  static func looksTranslated(_ output: String, raw: String) -> Bool {
    let spoken = Set(TextTools.words(raw))
    let written = TextTools.words(output)
    guard spoken.count >= 4, written.count >= 4 else { return false }
    let kept = written.filter { spoken.contains($0) }.count
    return Double(kept) < Double(written.count) * 0.5
  }

  /// Seconds for the model's answer: 8, and one more for every 400 characters, so that a long
  /// dictation gets cleaned too (at most 30; an organization's server stops at 20 anyway).
  public static func timeout(chars: Int) -> Double {
    min(30, 8 + Double(chars) / 400)
  }

  public struct Request: Sendable {
    public var raw: String
    public var entries: [VocabularyEntry]
    public var category: AppCategory
    public var style: String
    public var appName: String?
    public var insertion: Insertion
    /// Per-user key for the provider's prompt cache.
    public var cacheKey: String
    public var settings: ChatSettings
    public var fastPathMaxWords: Int
    /// Context from the screen (`DictationContext`), never part of the answer.
    public var textBefore: String? = nil
    public var screenText: String? = nil
  }

  public static func run(_ request: Request, chat: ChatService, now: EngineClock = EngineClocks.monotonic) async -> CleanupResult {
    let started = now()
    let raw = request.raw
    // Mid-sentence the model decides the case (proper name or not).
    if request.insertion == .start, !needsModel(raw, fastPathMaxWords: request.fastPathMaxWords) {
      return CleanupResult(
        text: fastClean(raw, entries: request.entries, category: request.category, insertion: request.insertion),
        path: .fast, ms: now() - started)
    }
    let model = request.settings.model
    let call = ChatCall(
      model: model,
      messages: Prompts.cleanup(
        dictionary: Vocabulary.promptList(request.entries), raw: raw, appName: request.appName,
        category: request.category, style: request.style, insertion: request.insertion,
        language: TextTools.dominantLanguage(raw), textBefore: request.textBefore, screenText: request.screenText),
      temperature: 0,
      maxTokens: raw.utf16.count / 2 + 64,
      reasoning: request.settings.reasoning ?? WantedReasoning.cleanup,
      prediction: request.settings.prediction ? raw : nil,
      cacheKey: "divoice-cleanup-\(request.cacheKey)",
      fastTier: request.settings.fastTier)
    let fallback = { fastClean(raw, entries: request.entries, category: request.category, insertion: request.insertion) }
    do {
      let result = try await chat.stream(call, timeout: timeout(chars: raw.utf16.count), onDelta: nil)
      let text = postProcess(result.text, entries: request.entries)
      if looksWrong(text, raw: raw) {
        return CleanupResult(
          text: fallback(), path: .fastFallback, model: model, ttftMs: result.ttftMs, ms: now() - started,
          error: "model answer discarded", discarded: text)
      }
      return CleanupResult(text: text, path: .llm, model: model, ttftMs: result.ttftMs, ms: now() - started)
    } catch {
      return CleanupResult(text: fallback(), path: .fastFallback, model: model, ms: now() - started, error: errorMessage(error))
    }
  }
}

/// Reasoning wanted by each step; the client maps it to what the model accepts.
enum WantedReasoning {
  static let cleanup = ReasoningLevel.none
  static let scribe = ReasoningLevel.low
  static let classifier = ReasoningLevel.none
}

public struct ScribeResult: Sendable, Equatable {
  public var text: String
  public var model: String
  public var ttftMs: Double?
  public var ms: Double
}

/// Writes a draft from a spoken instruction, or rewrites the selected text.
public enum Scribe {
  /// The request for a draft or a rewrite (also used by Verify and the bench).
  public static func call(_ input: Prompts.ScribeInput, settings: ChatSettings, maxTokens: Int? = nil) -> ChatCall {
    ChatCall(
      model: settings.model, messages: Prompts.scribe(input), temperature: temperature(input),
      maxTokens: maxTokens ?? Self.maxTokens(chars: length(input)),
      reasoning: settings.reasoning ?? WantedReasoning.scribe, fastTier: settings.fastTier)
  }

  /// What Scribe reads and rewrites: the dictation and the selected text.
  static func length(_ input: Prompts.ScribeInput) -> Int {
    input.instruction.utf16.count + (input.selectedText?.utf16.count ?? 0)
  }

  /// Seconds for the whole answer: a minute, and one more for every 40 characters, because the
  /// model reads, thinks about and rewrites all of a long dictation (at most 5 minutes).
  public static func timeout(chars: Int) -> Double {
    min(300, 60 + Double(chars) / 40)
  }

  /// Room for the answer: a rewrite is about as long as what it rewrites, a draft can be longer.
  static func maxTokens(chars: Int) -> Int {
    max(1_500, chars / 2 + 500)
  }

  /// A free rewrite of what was dictated gets more room than an edit of a selection
  /// (shorten, translate, fix), which should stay close to the instruction.
  static func temperature(_ input: Prompts.ScribeInput) -> Double {
    let refining = input.history.contains { $0.role == .assistant }
    let selection = input.selectedText?.isEmpty == false
    return refining || selection ? 0.2 : 0.4
  }

  public static func run(
    _ input: Prompts.ScribeInput, entries: [VocabularyEntry], settings: ChatSettings, chat: ChatService,
    onDelta: (@Sendable (String) -> Void)?
  ) async throws -> ScribeResult {
    let call = call(input, settings: settings)
    let result = try await chat.stream(call, timeout: timeout(chars: length(input)), onDelta: onDelta)
    return ScribeResult(
      text: Vocabulary.applyAliases(result.text.trimmingCharacters(in: .whitespacesAndNewlines), entries),
      model: settings.model, ttftMs: result.ttftMs, ms: result.totalMs)
  }
}

/// Decides whether a user's correction is about vocabulary (a name, brand, term) and returns
/// the term to learn, taken from the correction itself. It streams, so it also works through an
/// organization's server, which relays only streams and doesn't pass `response_format`: the JSON
/// is asked for in the prompt and read leniently.
public enum CorrectionClassifier {
  public static func learnedTerm(
    original: String, corrected: String, sentence: String?, settings: ChatSettings, chat: ChatService
  ) async throws -> String? {
    let call = ChatCall(
      model: settings.model, messages: Prompts.correction(original: original, corrected: corrected, sentence: sentence),
      temperature: 0, maxTokens: 80, reasoning: WantedReasoning.classifier)
    let content = try await chat.stream(call, timeout: 15, onDelta: nil).text
    guard let verdict = lenientJSON(content), verdict["vocabulary"] as? Bool == true,
      let term = (verdict["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty,
      corrected.lowercased().contains(term.lowercased())
    else { return nil }
    return term
  }

  /// The first JSON object in a text, also inside a code block or after a sentence.
  static func lenientJSON(_ text: String) -> [String: Any]? {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
    return JSON.object(String(text[open...close]))
  }
}
