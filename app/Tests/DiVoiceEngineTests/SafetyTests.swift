import Foundation
import Testing

@testable import DiVoiceEngine

@Suite("Safety")
struct SafetyTests {
  @Test func translatedCleanupIsDiscarded() {
    let raw = "Quick update, the Zentrix pilot went well and the client wants to extend it to the whole sales team."
    let translated = "Quick update: il pilota Zentrix è andato bene e il cliente vuole estenderlo a tutta la squadra vendite."
    #expect(Cleanup.looksTranslated(translated, raw: raw))
    #expect(Cleanup.looksWrong(translated, raw: raw))
    #expect(!Cleanup.looksWrong("Quick update: the Zentrix pilot went well, and the client wants to extend it to the whole sales team.", raw: raw))
  }

  @Test func normalCleanupsKeepTheSpokenWords() {
    let cases = [
      ("Ciao, ehm, ti confermo che la demo è giovedì alle quindici, anzi alle sedici.", "Ciao, ti confermo che la demo è giovedì alle 16."),
      ("chavo come va oggi con il progetto", "Ciao, come va oggi con il progetto?"),
      ("scrivi a nome chiocciola example punto com entro venerdì", "Scrivi a nome@example.com entro venerdì."),
      ("allora tre cose primo i numeri secondo i tempi terzo chi segue", "Tre cose: 1. i numeri; 2. i tempi; 3. chi segue."),
      ("Mandami il link del meeting e la recap della sessione", "Mandami il link del meeting e la recap della sessione."),
    ]
    for (raw, cleaned) in cases {
      #expect(!Cleanup.looksTranslated(cleaned, raw: raw), "\(cleaned)")
      #expect(!Cleanup.addsUnsaidWords(cleaned, raw: raw, entries: []), "\(cleaned)")
    }
    // Too short to judge.
    #expect(!Cleanup.looksTranslated("See you tomorrow.", raw: "Ci vediamo domani."))
  }

  /// Cleanups like the real ones of November 2026 (other names and texts), led astray by learned
  /// preferences or the text on screen.
  @Test func cleanupThatAddsGreetingsOrNamesIsDiscarded() {
    let wrong = [
      ("Marta Bellini.", "Ciao Marta!"),
      ("Giulia Ferraro.", "Ciao! Giulio Ferraro."),
      ("Preventivi, contatti fornitori.", "Preventivi, contatti fornitori! Ciao!"),
      ("Preventivi, contatto clienti.", "Ciao!  Preventivi, contatto clienti."),
      ("Riscrivimela qui con l'editor.", "Ciao!  Riscrivilo qui con l'editor."),
      (
        "Come ti abbiamo detto, da qui all'inizio di dicembre stiamo raccogliendo le adesioni dei partecipanti.",
        "Ciao,\n\nda qui all’inizio di dicembre stiamo raccogliendo le adesioni dei partecipanti.\n\nCordiali saluti\nMario Rossi"
      ),
      ("Ci vediamo giovedì in ufficio.", "Ci vediamo giovedì in ufficio.\n\nElena"),
      ("Guarda su Notion la parte di Budget e la parte di...", "Guarda su Notion la parte di Budget e la parte di Marketing."),
    ]
    for (raw, cleaned) in wrong {
      #expect(Cleanup.addsUnsaidWords(cleaned, raw: raw, entries: []), "\(cleaned)")
    }
    let right = [
      ("chavo come va oggi con il progetto", "Ciao, come va oggi con il progetto?"),
      ("ciao marco ti confermo la call di domani alle dieci grazie a presto tommaso", "Ciao Marco,\n\nti confermo la call di domani alle 10.\n\nGrazie, a presto\nTommaso"),
      ("Aspettiamo la persona con cui ho fatto la chiamata prima di Teralyon.", "Aspettiamo la persona con cui ho fatto la chiamata prima di Teralaion."),
      ("lascia che sia disponibile anche per chi scaricherà Dmail", "Lascia che sia disponibile anche per chi scaricherà diMail."),
      ("Domani vedo Marco, anzi Luca, alle dieci.", "Domani vedo Luca alle 10."),
      ("Marta Bellini.", "Marta Bellini"),
      ("ok la ringrazio le mando il file", "Ok, La ringrazio. Le mando il file."),
      ("I'll send it to Marco tonight", "I'll send it to Marco tonight."),
    ]
    for (raw, cleaned) in right {
      #expect(!Cleanup.addsUnsaidWords(cleaned, raw: raw, entries: []), "\(cleaned)")
    }
  }

  @Test func dictionaryAndOwnInstructionsMayAddWords() {
    let entry = VocabularyEntry(term: "Zentrix Hub", aliases: ["centrics hub"], scope: .team, source: .manual)
    #expect(!Cleanup.addsUnsaidWords("Il rinnovo di Zentrix Hub è ricorrente.", raw: "il rinnovo di centrics hub è ricorrente", entries: [entry]))
    #expect(Cleanup.addsUnsaidWords("Il rinnovo di Zentrix Hub è ricorrente.", raw: "il rinnovo di centrics hub è ricorrente", entries: []))
    let style = "A short work chat.\n" + StylePreferences(instructions: ["work_chat": "Firma sempre Tommaso."]).styles()["work_chat"]!
    #expect(!Cleanup.addsUnsaidWords("Ci vediamo domani.\n\nTommaso", raw: "ci vediamo domani", entries: [], style: style))
    #expect(Cleanup.addsUnsaidWords("Ci vediamo domani.\n\nTommaso", raw: "ci vediamo domani", entries: []))
    // Learned preferences are not the user's own instructions.
    let learned = StylePreferences().styles(learned: ["work_chat": "- Usare \"Sara\" come firma"])["work_chat"]!
    #expect(Cleanup.addsUnsaidWords("Ci vediamo domani.\n\nSara", raw: "ci vediamo domani", entries: [], style: learned))
  }

  @Test func cleanupThatEchoesThePromptIsDiscarded() {
    let echo = "App di destinazione: Claude (Codice e assistenti IA)\nStile: Trascrizione fedele e letterale.\n\nTrascrizione:\nAllora, nella nuova slide 12 dobbiamo cambiarla."
    #expect(Cleanup.echoesPrompt(echo))
    #expect(Cleanup.looksWrong(echo, raw: "Allora, nella nuova slide 12 dobbiamo cambiarla in questo modo, con un esempio in più."))
    #expect(Cleanup.echoesPrompt("Ok.\n<<<\nCiao Elena\n>>>"))
    #expect(!Cleanup.echoesPrompt("Stile: moderno, con colori chiari."))
  }

  @Test func transcriptLanguageIsDetectedOnTheDevice() {
    #expect(TextTools.dominantLanguage("Thanks. I'll send it over tonight.") == "en")
    #expect(TextTools.dominantLanguage("Ci vediamo domani alle dieci con tutto il team.") == "it")
    #expect(TextTools.dominantLanguage("Ho fatto il deploy in staging, ma il build è fallito per un timeout.") == "it")
    #expect(TextTools.dominantLanguage("Ok.") == nil)
  }

  @Test func cleanupNamesTheTranscriptLanguage() {
    let english = Prompts.cleanup(
      dictionary: "", raw: "Thanks. I'll send it over tonight.", appName: "Slack", category: .workChat, style: "Concise.",
      insertion: .start, language: "en")
    #expect(english[1].content.contains("Transcript language: English. Keep it"))
    let unknown = Prompts.cleanup(dictionary: "", raw: "Ok.", appName: nil, category: .other, style: "", insertion: .start)
    #expect(!unknown[1].content.contains("Transcript language"))
    // The system prompt doesn't change with the language: the provider's cache keeps working.
    let italian = Prompts.cleanup(
      dictionary: "", raw: "Ci vediamo domani.", appName: "Slack", category: .workChat, style: "Concise.", insertion: .start,
      language: "it")
    #expect(italian[0] == english[0])
    #expect(italian[1].content.contains("Transcript language: Italian."))
  }

  @Test func answerPrefixesAreRemovedInBothLanguages() {
    #expect(Cleanup.postProcess("Testo pulito: Ci vediamo domani.", entries: []) == "Ci vediamo domani.")
    #expect(Cleanup.postProcess("Cleaned text: See you tomorrow.", entries: []) == "See you tomorrow.")
    #expect(Cleanup.postProcess("Final text: \"See you tomorrow.\"", entries: []) == "See you tomorrow.")
    #expect(Cleanup.postProcess("Context matters here.", entries: []) == "Context matters here.")
  }

  @Test func reasoningLeavesRoomForTheAnswerWithBothProviders() {
    let input = Prompts.ScribeInput(userName: "", appName: nil, windowTitle: nil, category: .other, style: "", dictionary: "", instruction: "scrivi una frase")
    let large = ChatCompletionsClient(provider: .mistral, endpoint: .direct(.mistral, apiKey: "k"), http: FakeHTTP())
    let body = large.body(Scribe.call(input, settings: ChatSettings(provider: .mistral, model: "mistral-large-4-0"), maxTokens: 120), stream: true)
    #expect(body["reasoning_effort"] as? String == "low")
    #expect(body["max_tokens"] as? Int == 120 + ChatCompletionsClient.reasoningRoom)
    // Without reasoning the limit is the answer's own.
    let small = large.body(Scribe.call(input, settings: ChatSettings(provider: .mistral, model: "ministral-8b-2512"), maxTokens: 120), stream: true)
    #expect(small["max_tokens"] as? Int == 120)
    // A role's reasoning can be set: Small without reasoning, no room needed.
    let none = large.body(
      Scribe.call(input, settings: ChatSettings(provider: .mistral, model: "mistral-small-2603", reasoning: ReasoningLevel.none), maxTokens: 120),
      stream: true)
    #expect(none["reasoning_effort"] as? String == "none")
    #expect(none["max_tokens"] as? Int == 120)
    // Settings saved before the field existed still decode.
    let old = try? JSONDecoder().decode(ChatSettings.self, from: Data(#"{"provider":"mistral","model":"m","prediction":false,"fastTier":false}"#.utf8))
    #expect(old?.reasoning == nil)
  }

  @Test func scribeEditsTheDictationWithoutCarryingItOut() throws {
    let dictated = Prompts.scribe(
      Prompts.ScribeInput(
        userName: "Ada", appName: "Claude", windowTitle: nil, category: .other, style: "", dictionary: "",
        instruction: "scrivi un'email breve a Marco per spostare la call"))
    #expect(dictated[0].content.contains("never carry out what it asks"))
    #expect(dictated[0].content.contains("first person stays first person"))
    #expect(dictated[1].content == "Dictated text:\nscrivi un'email breve a Marco per spostare la call")
    let selected = Prompts.scribe(
      Prompts.ScribeInput(
        userName: "Ada", appName: "Mail", windowTitle: nil, category: .email, style: "", dictionary: "", instruction: "più formale",
        selectedText: "ciao, ti mando il file domani"))
    #expect(selected[0].content.contains("selected a text and dictated how to change it"))
    #expect(selected[1].content == "Instruction: più formale\n\nSelected text:\nciao, ti mando il file domani")
  }

  @Test func errorsNeverCarryKeys() {
    let masked = "Incorrect API key provided: sk-proj-****************************************1owA. You can find your API key at https://platform.openai.com/account/api-keys."
    let error = EngineError("realtime: \(masked) (invalid_api_key)")
    #expect(!error.message.contains("sk-"))
    #expect(!error.message.contains("1owA"))
    #expect(error.message.hasPrefix("realtime: Incorrect API key provided: [key]."))
    #expect(TextTools.redactSecrets("Authorization: Bearer abc.def-123 failed") == "Authorization: [key] failed")
    #expect(TextTools.redactSecrets("ask-me later, sk-1") == "ask-me later, sk-1")
  }

  @Test func httpErrorsShowTheProviderMessage() {
    let openAI = """
      {
        "error": {
          "message": "Incorrect API key provided: sk-proj-********1owA.",
          "type": "invalid_request_error",
          "code": "invalid_api_key"
        }
      }
      """
    #expect(errorMessage(HTTPStatusError(label: "batch", status: 401, body: openAI)) == "batch: HTTP 401 Incorrect API key provided: [key].")
    let mistral = #"{"object":"error","message":"Invalid model: voxtral-x","type":"invalid_model","code":"1500"}"#
    #expect(errorMessage(HTTPStatusError(label: "chat x", status: 400, body: mistral)) == "chat x: HTTP 400 Invalid model: voxtral-x")
    #expect(errorMessage(HTTPStatusError(label: "batch", status: 502, body: "<html>\n  Bad gateway\n</html>")) == "batch: HTTP 502 <html> Bad gateway </html>")
    #expect(errorMessage(HTTPStatusError(label: "batch", status: 401, body: "Unauthorized")) == "batch: HTTP 401 Unauthorized")
  }
}
