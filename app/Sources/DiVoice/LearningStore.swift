import Combine
import DiVoiceEngine
import Foundation

/// What diVoice learns from the user's corrections, on this Mac only
/// (Application Support/DiVoice/learning.json): the corrections waiting to be learned, for 7 days
/// at most, and the preferences learned for each kind of app.
@MainActor
final class LearningStore: ObservableObject {
  static let shared = LearningStore()

  struct WordCorrection: Codable, Equatable {
    var date: Date
    var original: String
    var corrected: String
    var sentence: String
  }

  struct State: Codable, Equatable {
    /// Rewrites per category raw value, waiting for the next summary.
    var pairs: [String: [CorrectionPair]] = [:]
    /// Preferences per category raw value.
    var learned: [String: String] = [:]
    /// Replaced words, waiting for the classifier.
    var words: [WordCorrection] = []
    /// 2 since 0.6.3. Missing in older files, whose preferences could ask for greetings and
    /// signatures the user never said.
    var version: Int?
  }

  static let version = 2

  @Published private(set) var state = State()
  private let url: URL?
  private let ioQueue = DispatchQueue(label: "app.wibo.divoice.learning")

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DiVoice", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let url = base.appendingPathComponent("learning.json")
    self.url = url
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let data = try? Data(contentsOf: url), let saved = try? decoder.decode(State.self, from: data) { state = saved }
    if (state.version ?? 0) < Self.version {
      // Learned before 0.6.3: start over (the replaced words stay).
      state.learned = [:]
      state.pairs = [:]
      state.version = Self.version
      save()
    }
    prune()
  }

  /// Sample preferences for the screenshots: nothing is read or written.
  init(preview learned: [String: String]) {
    url = nil
    state = State(learned: learned)
  }

  var learned: [String: String] { state.learned }

  func waiting(_ category: AppCategory) -> Int { state.pairs[category.rawValue]?.count ?? 0 }

  func record(_ correction: Correction, category: AppCategory) {
    switch correction {
    case let .words(original, corrected, sentence):
      state.words.append(WordCorrection(date: Date(), original: original, corrected: corrected, sentence: sentence))
      state.words = Array(state.words.suffix(10))
    case let .rewrite(before, after):
      // Code stays literal, and the other apps (search fields, forms, AI assistants) have no
      // style of their own: nothing to learn there.
      guard category != .code, category != .other else { return }
      state.pairs[category.rawValue, default: []].append(CorrectionPair(before: before, after: after))
      state.pairs[category.rawValue] = Array(state.pairs[category.rawValue]!.suffix(StyleLearning.batch * 2))
    }
    prune()
    save()
  }

  /// Settings › Style: the user edits or clears what was learned.
  func setLearned(_ text: String, for category: AppCategory) {
    let text = String(text.prefix(StylePreferences.maxInstructions))
    state.learned[category.rawValue] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    save()
  }

  func forget(_ category: AppCategory) {
    state.learned[category.rawValue] = nil
    state.pairs[category.rawValue] = nil
    save()
  }

  /// Runs what's waiting, at most `limit` model calls, with the chat of the dictation that just
  /// ended (through the organization's server, if any). Returns the terms added to the dictionary.
  func runPending(chat: ChatService, settings: ChatSettings, limit: Int) async -> [String] {
    var calls = 0
    var terms: [String] = []
    while calls < limit, let word = state.words.first {
      state.words.removeFirst()
      save()
      calls += 1
      let term = try? await CorrectionClassifier.learnedTerm(
        original: word.original, corrected: word.corrected, sentence: word.sentence, settings: settings, chat: chat)
      if let term {
        VocabularyStore.shared.add(term: term, aliases: [word.original], source: .learned)
        terms.append(term)
      }
    }
    for category in AppCategory.allCases where calls < limit {
      let key = category.rawValue
      guard let pairs = state.pairs[key], pairs.count >= StyleLearning.batch else { continue }
      calls += 1
      do {
        let lines = try await StyleLearning.run(
          current: state.learned[key], pairs: pairs, category: category, language: Self.language, settings: settings, chat: chat)
        if let lines { state.learned[key] = lines }
        // A useless answer doesn't come back: these corrections are done.
        state.pairs[key] = nil
        save()
      } catch {
        // The provider failed: the corrections wait for the next dictation.
      }
    }
    return terms
  }

  /// The interface's language, in English, for the learned lines.
  private static var language: String {
    let code = Locale.current.language.languageCode?.identifier ?? "en"
    return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English"
  }

  private func prune() {
    let limit = Date().addingTimeInterval(-7 * 86_400)
    state.words.removeAll { $0.date < limit }
    for key in state.pairs.keys {
      state.pairs[key]?.removeAll { $0.date < limit }
      if state.pairs[key]?.isEmpty == true { state.pairs[key] = nil }
    }
  }

  private func save() {
    guard let url else { return }
    let snapshot = state
    ioQueue.async {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      guard let data = try? encoder.encode(snapshot) else { return }
      try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
  }
}
