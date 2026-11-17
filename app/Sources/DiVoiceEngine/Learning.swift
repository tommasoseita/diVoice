import Foundation

/// What the user changed in a dictated text after it was inserted.
public enum Correction: Sendable, Equatable {
  /// One to three words replaced: maybe a name or a term the transcription got wrong.
  case words(original: String, corrected: String, sentence: String)
  /// A wider edit inside the dictated text: a sign of how the user likes to write.
  case rewrite(before: String, after: String)
}

/// Finds the user's correction by comparing the field right after the insertion with the field
/// when they moved on. Only edits inside the dictated text count: text typed before or after it,
/// changes elsewhere in the field, deleting it all or rewriting most of it are not corrections.
public enum CorrectionDiff {
  /// Beyond this share of the dictated text changed, the user wrote something else.
  static let maxChangedShare = 0.6

  /// `inserted` is where the dictated text is in `baseline`, in UTF-16 units (as Accessibility counts).
  public static func find(baseline: String, inserted: NSRange, final: String) -> Correction? {
    let old = baseline as NSString
    let new = final as NSString
    guard inserted.location != NSNotFound, inserted.length > 0, NSMaxRange(inserted) <= old.length, baseline != final else { return nil }

    var prefix = 0
    let shorter = min(old.length, new.length)
    while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
    var suffix = 0
    while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
    let start = prefix
    let oldEnd = old.length - suffix
    let newEnd = new.length - suffix
    let dictatedStart = inserted.location
    let dictatedEnd = NSMaxRange(inserted)

    guard start >= dictatedStart, oldEnd <= dictatedEnd else { return nil }
    // Pure typing at either end of the dictated text continues it, it doesn't correct it.
    if start == oldEnd, start == dictatedStart || start == dictatedEnd { return nil }
    // So does typing that only replaces the punctuation at an end ("…domani." → "…domani in ufficio").
    let removed = old.substring(with: NSRange(location: start, length: oldEnd - start))
    let typed = new.substring(with: NSRange(location: start, length: max(0, newEnd - start)))
    if oldEnd == dictatedEnd || start == dictatedStart,
      removed.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).isEmpty,
      TextTools.wordCount(typed) > 0
    {
      return nil
    }

    let original = old.substring(with: inserted)
    let corrected = new.substring(with: NSRange(location: dictatedStart, length: inserted.length + new.length - old.length))
    guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    // The words the edit touched, whole.
    let before = wordSpan(old, start, oldEnd)
    let after = wordSpan(new, start, newEnd)
    let beforeWords = TextTools.wordCount(before)
    let afterWords = TextTools.wordCount(after)
    if (1...3).contains(beforeWords), (1...3).contains(afterWords), before != after {
      return .words(original: before, corrected: after, sentence: String(corrected.prefix(300)))
    }
    // Most of the dictated words gone: the user wrote something else.
    let spoken = TextTools.words(original)
    let kept = Set(TextTools.words(corrected))
    guard Double(spoken.filter(kept.contains).count) >= Double(spoken.count) * (1 - maxChangedShare) else { return nil }
    return .rewrite(before: original, after: corrected)
  }

  private static func isWordUnit(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return true }  // half of a surrogate pair: part of a word
    return CharacterSet.alphanumerics.contains(scalar) || "'’-".unicodeScalars.contains(scalar)
  }

  /// The range widened to whole words, trimmed of spaces and punctuation.
  private static func wordSpan(_ text: NSString, _ start: Int, _ end: Int) -> String {
    var lower = start
    var upper = end
    while lower > 0, isWordUnit(text.character(at: lower - 1)) { lower -= 1 }
    while upper < text.length, isWordUnit(text.character(at: upper)) { upper += 1 }
    guard upper > lower else { return "" }
    return text.substring(with: NSRange(location: lower, length: upper - lower))
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
  }
}

/// A pair for the style summary: the text as diVoice inserted it, and as the user left it.
public struct CorrectionPair: Codable, Sendable, Equatable {
  public var date: Date
  public var before: String
  public var after: String

  public init(date: Date = Date(), before: String, after: String) {
    self.date = date
    self.before = before
    self.after = after
  }
}

/// Turns the user's corrections in one kind of app into a few lines of preferences, which then
/// join that kind's style.
public enum StyleLearning {
  /// Corrections collected in a kind of app before the preferences are updated.
  public static let batch = 5

  static func system(language: String) -> String {
    """
    You learn how a user likes their dictated text written, from the corrections they make after diVoice inserts it.
    You get their current preferences (maybe none) and pairs of texts: as diVoice wrote it, and as the user left it.
    Write the updated preferences: at most 6 short lines, each starting with "- ", only about how the user's own words are written: punctuation, capital letters, line breaks and paragraphs, formality ("tu" or "Lei"), and words they keep replacing with others. Only patterns that at least two corrections show. Keep earlier preferences unless the corrections contradict them.
    Some pairs aren't corrections at all (the user went on typing, or wrote something else): ignore what they added.
    Never write a preference that adds words the user didn't say: no greetings, sign-offs, signatures or names. Never include facts, topics or names from the texts.
    If nothing qualifies, reply with the current preferences unchanged, or with "none" if there are none.
    Write the lines in \(language). Reply with the lines only.
    """
  }

  /// Lines about greetings, sign-offs or signatures: whatever the model meant, they lead the
  /// cleanup to add words the user didn't say, so they never join the style.
  private static let addsWords = TextTools.regex(
    "(?<![\\p{L}])(salut|firm|chiusur|commiat|greet|sign|closing|valediction)", ignoreCase: true)

  public static func messages(current: String?, pairs: [CorrectionPair], category: AppCategory, language: String) -> [ChatMessage] {
    var user = "Kind of app: \(Categories.promptLabels[category] ?? category.rawValue)\n\nCurrent preferences:\n"
    user += current?.isEmpty == false ? current! : "(none)"
    user += "\n\nCorrections:"
    for (index, pair) in pairs.suffix(batch * 2).enumerated() {
      user += "\n\(index + 1). Written: \(pair.before.prefix(1_500))\n   Left as: \(pair.after.prefix(1_500))"
    }
    return [ChatMessage(role: .system, content: system(language: language)), ChatMessage(role: .user, content: user)]
  }

  /// The new preferences, or nil when the model's answer isn't a short list.
  public static func run(
    current: String?, pairs: [CorrectionPair], category: AppCategory, language: String, settings: ChatSettings, chat: ChatService
  ) async throws -> String? {
    let call = ChatCall(
      model: settings.model, messages: messages(current: current, pairs: pairs, category: category, language: language),
      temperature: 0, maxTokens: 300, reasoning: WantedReasoning.classifier)
    let text = try await chat.stream(call, timeout: 20, onDelta: nil).text
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("-") && !TextTools.matches(addsWords, $0) }
    guard !lines.isEmpty else { return nil }
    return String(lines.prefix(6).joined(separator: "\n").prefix(StylePreferences.maxInstructions))
  }
}
