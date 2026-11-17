import Foundation
import NaturalLanguage

/// Small text helpers shared by the pipeline (ICU regular expressions, Unicode aware).
public enum TextTools {
  private static let wordPattern = regex("[\\p{L}\\p{N}][\\p{L}\\p{N}'’\\-]*")
  private static let whitespace = regex("\\s+")

  /// Words as the dictation statistics count them.
  public static func wordCount(_ text: String) -> Int {
    wordPattern.numberOfMatches(in: text, range: fullRange(text))
  }

  /// The dominant language of a text as a two-letter code, detected on the device, when the
  /// recognizer is confident. A mixed Italian/English sentence reports its main language.
  public static func dominantLanguage(_ text: String, minimumConfidence: Double = 0.6) -> String? {
    guard wordCount(text) >= 2 else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= minimumConfidence
    else { return nil }
    return String(language.rawValue.prefix(2))
  }

  /// Lowercased words, for comparing two texts.
  /// Words that start with a capital letter in the middle of a sentence, or that make up a short
  /// line on their own (a signature): likely names. Acronyms and "I" don't count.
  static func capitalizedWords(_ text: String) -> [String] {
    let ns = text as NSString
    var out: [String] = []
    for match in wordPattern.matches(in: text, range: fullRange(text)) {
      let word = ns.substring(with: match.range)
      guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
        word.count >= 2, word != word.uppercased(), !word.lowercased().hasPrefix("i'"), !word.lowercased().hasPrefix("i’")
      else { continue }
      if !startsSentence(ns, at: match.range.location) || isShortLine(ns, around: match.range) { out.append(word) }
    }
    return out
  }

  /// Whether only spaces, opening quotes or brackets separate the word from the start of the text,
  /// a line break, or the end of a sentence.
  private static func startsSentence(_ text: NSString, at location: Int) -> Bool {
    var index = location - 1
    while index >= 0 {
      guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
      if scalar == "\n" || ".!?…:".unicodeScalars.contains(scalar) { return true }
      if scalar == " " || scalar == "\t" || "\"“«(‘'[".unicodeScalars.contains(scalar) {
        index -= 1
        continue
      }
      return false
    }
    return true
  }

  /// A line of at most three words, all capitalized, such as "Mario Rossi" under an email.
  private static func isShortLine(_ text: NSString, around range: NSRange) -> Bool {
    let line = text.substring(with: text.lineRange(for: range)).trimmingCharacters(in: .whitespacesAndNewlines)
    let words = wordPattern.matches(in: line, range: fullRange(line)).map { (line as NSString).substring(with: $0.range) }
    guard (1...3).contains(words.count), line.count < 40 else { return false }
    // Text that goes on after the last sentence's end isn't a signature line.
    guard line.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) == nil else { return false }
    return words.allSatisfy { $0.first?.isUppercase == true }
  }

  /// Two words close enough to be the same word misheard: at most a third of the letters differ
  /// (two in short words).
  static func isClose(_ a: String, _ b: String) -> Bool {
    let a = Array(a)
    let b = Array(b)
    let limit = max(2, max(a.count, b.count) / 3)
    guard abs(a.count - b.count) <= limit else { return false }
    guard !a.isEmpty, !b.isEmpty else { return true }
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
      }
      previous = current
    }
    return previous[b.count] <= limit
  }

  public static func words(_ text: String) -> [String] {
    let lower = text.lowercased()
    return wordPattern.matches(in: lower, range: fullRange(lower)).compactMap { match in
      Range(match.range, in: lower).map { String(lower[$0]) }
    }
  }

  private static let secretPattern = regex("\\bsk[-_][A-Za-z0-9_*\\-]{6,}|\\bBearer\\s+[^\\s\"']+")

  /// API keys and bearer tokens, even masked ones (OpenAI repeats part of the key in its
  /// errors), are replaced before a message reaches the logs or the user.
  public static func redactSecrets(_ text: String) -> String {
    secretPattern.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: "[key]")
  }

  /// Collapses runs of whitespace into one space.
  public static func collapseWhitespace(_ text: String) -> String {
    whitespace.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: " ")
  }

  static func regex(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
    // Patterns are built by this module; an invalid one is a programming error.
    try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
  }

  static func fullRange(_ text: String) -> NSRange {
    NSRange(text.startIndex..., in: text)
  }

  static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: fullRange(text)) != nil
  }

  static func escape(_ text: String) -> String {
    NSRegularExpression.escapedPattern(for: text)
  }

  /// Replaces every match with the string returned by `transform`.
  static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (String) -> String) -> String {
    let matches = regex.matches(in: text, range: fullRange(text))
    guard !matches.isEmpty else { return text }
    var out = ""
    var cursor = text.startIndex
    for match in matches {
      guard let range = Range(match.range, in: text) else { continue }
      out += text[cursor..<range.lowerBound]
      out += transform(String(text[range]))
      cursor = range.upperBound
    }
    out += text[cursor...]
    return out
  }

  private static let mixedCase = regex("(?<![\\p{L}])\\p{L}*\\p{Ll}\\p{Lu}[\\p{L}\\p{N}]*")

  /// Names of people, organizations and places in a text, found on the device, most frequent
  /// first, plus words in mixed case (HubSpot, iPhone) that are usually product names: the
  /// screen's names for the transcription's vocabulary.
  public static func names(in text: String, limit: Int = 10) -> [String] {
    var found: [String: (name: String, count: Int, first: Int)] = [:]
    var order = 0
    func add(_ name: String) {
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      guard name.count >= 3, name.count <= 40 else { return }
      found[name.lowercased(), default: (name, 0, order)].count += 1
      order += 1
    }
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    let kinds: Set<NLTag> = [.personalName, .organizationName, .placeName]
    tagger.enumerateTags(
      in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]
    ) { tag, range in
      if let tag, kinds.contains(tag) { add(String(text[range])) }
      return true
    }
    for match in mixedCase.matches(in: text, range: fullRange(text)) {
      if let range = Range(match.range, in: text) { add(String(text[range])) }
    }
    return found.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }.prefix(limit).map(\.name)
  }

  /// "auto" or anything that isn't a two-letter code means automatic detection.
  public static func normalizeLanguage(_ value: String?) -> String? {
    guard let lang = value?.lowercased(), lang != "auto", !lang.isEmpty else { return nil }
    return lang.range(of: "^[a-z]{2}$", options: .regularExpression) != nil ? lang : nil
  }
}
