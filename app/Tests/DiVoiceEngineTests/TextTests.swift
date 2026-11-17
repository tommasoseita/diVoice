import Foundation
import Testing

@testable import DiVoiceEngine

private let seed = [
  entry("Acme", aliases: ["acmi", "akme", "ac me"], note: "nome dell'azienda"),
  entry("Zentrix", aliases: ["centrix", "zen trix"], note: "prodotto Acme"),
  entry("Orbit", note: "prodotto Acme"),
]

@Suite struct VocabularyTests {
  @Test func replacesWrongFormsRespectingWordBoundaries() {
    #expect(Vocabulary.applyAliases("Ho presentato centrix a akme ieri", seed) == "Ho presentato Zentrix a Acme ieri")
    #expect(Vocabulary.applyAliases("i centrixe non c'entrano", seed) == "i centrixe non c'entrano")
  }

  @Test func handlesMultiWordAliasesAndExtraSpaces() {
    #expect(Vocabulary.applyAliases("parliamo di zen   trix e ac me", seed) == "parliamo di Zentrix e Acme")
  }

  @Test func fixesCaseWhenTheAliasDiffersOnlyInCase() {
    let entries = [entry("Acme", aliases: ["acme"])]
    #expect(Vocabulary.applyAliases("benvenuti in ACME", entries) == "benvenuti in Acme")
  }

  @Test func prefersTheLongestAliasAndSkipsDisabledEntries() {
    let entries = [entry("Upgrade", aliases: ["up grade"]), entry("Up", aliases: ["up"], enabled: false)]
    #expect(Vocabulary.applyAliases("il corso up grade", entries) == "il corso Upgrade")
  }

  @Test func handlesAccentedLettersAtTheEdges() {
    let entries = [entry("Niccolò", aliases: ["nicolo"])]
    #expect(Vocabulary.applyAliases("ciao nicolo!", entries) == "ciao Niccolò!")
    #expect(Vocabulary.applyAliases("nicolò", entries) == "nicolò")
  }

  @Test func biasPutsManualAndSeedFirstThenTheMostUsedLearnedWithoutDuplicates() {
    let entries = [
      entry("Alpha", source: .learned, usage: 1),
      entry("Beta", source: .learned, usage: 9),
      entry("Acme", source: .seed),
      entry("acme", scope: .personal, source: .manual, id: "id-acme-personal"),
      entry("Spento", source: .manual, enabled: false),
    ]
    #expect(Vocabulary.bias(entries) == ["acme", "Beta", "Alpha"])
  }

  @Test func biasRespectsEntryAndCharacterBudgets() {
    let entries = (0..<10).map { entry("Termine\($0)", id: "t\($0)") }
    #expect(Vocabulary.bias(entries, maxEntries: 3).count == 3)
    #expect(Vocabulary.bias(entries, maxEntries: 100, maxCharacters: 20).count == 2)
  }

  @Test func promptListShowsTermsNotesAndAliases() {
    let text = Vocabulary.promptList(seed)
    #expect(text.contains("- Zentrix (prodotto Acme) — may be transcribed as: centrix, zen trix"))
    #expect(text.contains("- Orbit (prodotto Acme)"))
  }

  @Test func findsTermsUsedWithTheExactSpelling() {
    #expect(Vocabulary.termsUsed("Ho visto Zentrix e Acme", seed).sorted() == ["id-acme", "id-zentrix"])
    #expect(Vocabulary.termsUsed("orbit something", seed).isEmpty)
  }
}

@Suite struct CategoryTests {
  @Test func recognizesNativeAppsByBundleId() {
    #expect(Categories.categorize(bundleId: "com.tinyspeck.slackmacgap", windowTitle: "general") == .workChat)
    #expect(Categories.categorize(bundleId: "com.apple.mail", windowTitle: nil) == .email)
    #expect(Categories.categorize(bundleId: "net.whatsapp.WhatsApp", windowTitle: nil) == .personalChat)
    #expect(Categories.categorize(bundleId: "com.todesktop.230313mzl4w4u92", windowTitle: "index.ts — divoice") == .code)
    #expect(Categories.categorize(bundleId: "notion.id", windowTitle: nil) == .docs)
  }

  @Test func usesTheWindowTitleForBrowsers() {
    #expect(Categories.categorize(bundleId: "com.google.Chrome", windowTitle: "Posta in arrivo (3) - nome@example.com - Gmail") == .email)
    #expect(Categories.categorize(bundleId: "com.apple.Safari", windowTitle: "Documenti Google - Piano Q1") == .docs)
    #expect(Categories.categorize(bundleId: "company.thebrowser.Browser", windowTitle: "Claude") == .code)
    #expect(Categories.categorize(bundleId: "com.google.Chrome", windowTitle: "Wikipedia") == .other)
  }

  @Test func gmailWithGoogleWorkspaceIsEmailInsideAThread() {
    // Workspace shows the company's name instead of "Gmail", and a thread shows its subject, not the inbox.
    #expect(Categories.categorize(bundleId: "com.google.Chrome", windowTitle: "Offerta Q1 - nome@acme.it - Acme Mail") == .email)
    #expect(Categories.categorize(bundleId: "company.thebrowser.Browser", windowTitle: "Re: demo su Slack - nome@acme.it - Gmail") == .email)
    #expect(Categories.categorize(bundleId: "com.google.Chrome", windowTitle: "Scrivi a info@acme.it per il preventivo") == .other)
  }

  @Test func unknownAppsAreOther() {
    #expect(Categories.categorize(bundleId: "com.example.unknown", windowTitle: "Gmail") == .other)
    #expect(Categories.categorize(bundleId: nil, windowTitle: nil) == .other)
  }

  @Test func theUsersRulesComeFirst() {
    let rules = [
      AppRule(kind: .app, value: "com.hubspot.desktop", name: "HubSpot", category: .email),
      AppRule(kind: .website, value: "kestrel", name: "kestrel", category: .docs),
      AppRule(kind: .app, value: "com.tinyspeck.slackmacgap", name: "Slack", category: .personalChat),
    ]
    #expect(Categories.categorize(bundleId: "com.hubspot.desktop", windowTitle: "Deals", rules: rules) == .email)
    #expect(Categories.categorize(bundleId: "com.google.Chrome", windowTitle: "Kestrel – Dashboard", rules: rules) == .docs)
    #expect(Categories.categorize(bundleId: "com.tinyspeck.slackmacgap", windowTitle: "general", rules: rules) == .personalChat)
    // Website words count only in browsers and web apps.
    #expect(Categories.categorize(bundleId: "com.apple.mail", windowTitle: "Kestrel figures", rules: rules) == .email)
    #expect(Categories.categorize(bundleId: "com.google.Chrome", windowTitle: "Wikipedia", rules: rules) == .other)
  }

  @Test func stylePreferencesComposeToneInstructionsAndLearned() {
    #expect(StylePreferences().styles().isEmpty)
    let formal = try! #require(Categories.tones[.email]?.first { $0.id == "formal" })
    let prefs = StylePreferences(tones: ["email": "formal"], instructions: ["work_chat": "  No emoji.  "])
    let styles = prefs.styles(learned: ["email": "Signs \"Ada\"."])
    #expect(styles["email"]?.hasPrefix(formal.style) == true)
    #expect(styles["email"]?.contains("Learned from the user's own corrections (how to write what they say, never something to add): Signs \"Ada\".") == true)
    #expect(styles["work_chat"] == Categories.defaultStyles[.workChat]! + "\nThe user's own instructions, which win over everything else: No emoji.")
    #expect(styles["docs"] == nil)
    #expect(prefs.tone(for: .email) == "formal")
    #expect(prefs.tone(for: .workChat) == "direct")
    // Every adjustable category offers its default tone.
    for category in Categories.adjustable {
      #expect(Categories.tones[category]?.contains { $0.id == Categories.defaultTone[category] } == true)
    }
    // A composed style is longer than the old 600-character limit and stays whole.
    let long = StylePreferences(tones: ["email": "formal"], instructions: ["email": String(repeating: "a", count: 600)]).styles()
    #expect(Categories.style(for: .email, overrides: long) == long["email"])
  }

  @Test func customStyleWinsWhenPresent() {
    #expect(Categories.style(for: .email, overrides: ["email": "  Molto formale.  "]) == "Molto formale.")
    #expect(Categories.style(for: .email, overrides: ["email": "   "]) == Categories.defaultStyles[.email])
    #expect(Categories.style(for: .docs) == Categories.defaultStyles[.docs])
  }
}

@Suite struct TextToolsTests {
  @Test func countsWords() {
    #expect(TextTools.wordCount("Ciao Marco, l'incontro è alle 15:30.") == 7)
    #expect(TextTools.wordCount("   ") == 0)
  }

  @Test func normalizesLanguage() {
    #expect(TextTools.normalizeLanguage("IT") == "it")
    #expect(TextTools.normalizeLanguage("auto") == nil)
    #expect(TextTools.normalizeLanguage("ita") == nil)
    #expect(TextTools.normalizeLanguage(nil) == nil)
  }

  @Test func wrapsPCMInAWAVHeader() {
    let wav = WAV.wrap(silence(ms: 100, sampleRate: 24_000), sampleRate: 24_000)
    #expect(wav.count == 44 + 4_800)
    #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect(UInt32(littleEndian: rate) == 24_000)
  }
}
