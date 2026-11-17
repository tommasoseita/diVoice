import Foundation
import Testing

@testable import DiVoiceEngine

@Suite struct LearningTests {
  /// The field after inserting `dictated` after `before`, and where it is.
  private func inserted(_ before: String, _ dictated: String, _ after: String = "") -> (String, NSRange) {
    (before + dictated + after, NSRange(location: (before as NSString).length, length: (dictated as NSString).length))
  }

  @Test func aReplacedNameIsAWordCorrection() {
    let (baseline, range) = inserted("Ciao,\n", "domani vediamo Zentrics alle 10.")
    let correction = CorrectionDiff.find(baseline: baseline, inserted: range, final: "Ciao,\ndomani vediamo Zentrix alle 10.")
    #expect(correction == .words(original: "Zentrics", corrected: "Zentrix", sentence: "domani vediamo Zentrix alle 10."))
    let twoWords = CorrectionDiff.find(baseline: baseline, inserted: range, final: "Ciao,\ndomani vediamo Matteo Rossi alle 10.")
    #expect(twoWords == .words(original: "Zentrics", corrected: "Matteo Rossi", sentence: "domani vediamo Matteo Rossi alle 10."))
  }

  @Test func aWiderEditIsARewrite() {
    let (baseline, range) = inserted("", "Ciao Marco ti confermo la call di domani alle dieci grazie")
    let final = "Ciao Marco,\n\nti confermo la call di domani alle dieci.\n\nGrazie"
    #expect(
      CorrectionDiff.find(baseline: baseline, inserted: range, final: final)
        == .rewrite(before: "Ciao Marco ti confermo la call di domani alle dieci grazie", after: final))
  }

  @Test func typingAroundOrReplacingEverythingIsNotACorrection() {
    let (baseline, range) = inserted("Oggetto: demo\n", "Ci vediamo domani.", "\nA presto")
    // Text typed after the dictated text, or before it.
    #expect(CorrectionDiff.find(baseline: baseline, inserted: range, final: baseline.replacingOccurrences(of: "domani.", with: "domani. Porta il PC.")) == nil)
    #expect(CorrectionDiff.find(baseline: baseline, inserted: range, final: "Oggetto: demo\nOk. Ci vediamo domani.\nA presto") == nil)
    // A change elsewhere in the field.
    #expect(CorrectionDiff.find(baseline: baseline, inserted: range, final: baseline.replacingOccurrences(of: "A presto", with: "Grazie")) == nil)
    // Deleted, or rewritten from scratch.
    #expect(CorrectionDiff.find(baseline: baseline, inserted: range, final: "Oggetto: demo\n\nA presto") == nil)
    #expect(CorrectionDiff.find(baseline: baseline, inserted: range, final: "Oggetto: demo\nNon posso venire, scusa.\nA presto") == nil)
    // Unchanged.
    #expect(CorrectionDiff.find(baseline: baseline, inserted: range, final: baseline) == nil)
    // Going on typing after removing the final period.
    let (chat, chatRange) = inserted("", "Sì, ci vediamo tra dieci giorni. Ne parliamo domani.")
    #expect(CorrectionDiff.find(baseline: chat, inserted: chatRange, final: "Sì, ci vediamo tra dieci giorni. Ne parliamo domani in uffi") == nil)
    // Changing only the punctuation is still a correction.
    #expect(CorrectionDiff.find(baseline: chat, inserted: chatRange, final: "Sì, ci vediamo tra dieci giorni. Ne parliamo domani!") != nil)
  }

  @Test func styleLearningAsksForShortLinesWithoutTheTextsFacts() {
    let pairs = [CorrectionPair(before: "ciao marco ok", after: "Ciao Marco,\n\nok.")]
    let messages = StyleLearning.messages(current: "- Signs \"Ada\".", pairs: pairs, category: .email, language: "Italian")
    #expect(messages[0].content.contains("Write the lines in Italian."))
    #expect(messages[0].content.contains("Never include facts, topics or names from the texts"))
    #expect(messages[1].content.contains("Kind of app: Email"))
    #expect(messages[1].content.contains("- Signs \"Ada\"."))
    #expect(messages[1].content.contains("1. Written: ciao marco ok\n   Left as: Ciao Marco,\n\nok."))
  }

  @Test func styleLearningKeepsOnlyTheListLines() async throws {
    let http = FakeHTTP(pieces: [
      "Here are the preferences:\n", "- Greets with \"Ciao Nome,\" on its own line.\n", "- Signs \"Ada\".\n",
      "- Usare \"Elena\" come nome di chiusura\n", "- Usare \"Ciao\" come saluto iniziale\n",
      "- No final period in short messages.\n",
    ])
    let chat = ChatCompletionsClient(provider: .mistral, endpoint: .direct(.mistral, apiKey: "k"), http: http)
    let lines = try await StyleLearning.run(
      current: nil, pairs: [CorrectionPair(before: "a", after: "b")], category: .email, language: "English",
      settings: .cleanupDefaults(.mistral), chat: chat)
    // Greetings, sign-offs and signatures never join the style.
    #expect(lines == "- No final period in short messages.")
  }

  @Test func styleLearningNeverAsksForGreetingsOrSignatures() {
    let system = StyleLearning.messages(current: nil, pairs: [], category: .workChat, language: "Italian")[0].content
    #expect(system.contains("no greetings, sign-offs, signatures or names"))
    #expect(system.contains("Only patterns that at least two corrections show"))
  }
}
