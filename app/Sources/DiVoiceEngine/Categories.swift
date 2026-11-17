import Foundation

/// The kind of app the text goes into; it decides the tone of the cleanup.
public enum AppCategory: String, Codable, Sendable, CaseIterable {
  case email
  case workChat = "work_chat"
  case personalChat = "personal_chat"
  case docs
  case code
  case other
}

public enum Categories {
  /// Default style per category. They are part of the prompts, so they follow the prompt language.
  public static let defaultStyles: [AppCategory: String] = [
    .email:
      "A work email, written rather than spoken. Lay it out as an email: the greeting on its own line, then a blank line; the body in short paragraphs, one per topic, with a blank line between them; the closing on its own line after a blank line, with the name below it if dictated. Professional and courteous register: turn spoken phrasing into complete, well-formed written sentences and drop spoken connectives (\"allora\", \"niente\", \"praticamente\", \"so\", \"basically\"), keeping the user's \"tu\" or \"Lei\", their words for facts, and their intent. Don't add greetings, closings or signatures they didn't say.",
    .workChat:
      "Professional but direct and concise, as in Slack. No added pleasantries. Bulleted lists only if the user dictates a list.",
    .personalChat:
      "Informal, natural, conversational tone. No period after the last sentence (question and exclamation marks stay).",
    .docs: "Carefully written text with correct punctuation. Use paragraphs or lists if the dictated structure suggests them.",
    .code:
      "Faithful, literal transcript. Don't rephrase or change technical terms, file names, functions, commands or identifiers. Fix only fillers and punctuation.",
    .other: "Neutral tone: fix punctuation and fillers without changing the register.",
  ]

  /// Category names as they appear in the prompts.
  static let promptLabels: [AppCategory: String] = [
    .email: "Email",
    .workChat: "Work chat",
    .personalChat: "Personal chat",
    .docs: "Documents and notes",
    .code: "Code and AI assistants",
    .other: "Other apps",
  ]

  private static let bundles: [String: AppCategory] = [
    // Email
    "com.apple.mail": .email,
    "com.microsoft.Outlook": .email,
    "com.superhuman.electron": .email,
    "com.readdle.SparkDesktop": .email,
    "com.readdle.smartemail-Mac": .email,
    "it.bloop.airmail2": .email,
    "com.mimestream.Mimestream": .email,
    "com.google.Gmail": .email,
    // Work chat
    "com.tinyspeck.slackmacgap": .workChat,
    "com.microsoft.teams2": .workChat,
    "com.microsoft.teams": .workChat,
    "com.google.Chat": .workChat,
    "us.zoom.xos": .workChat,
    "com.linear": .workChat,
    // Personal chat
    "net.whatsapp.WhatsApp": .personalChat,
    "desktop.WhatsApp": .personalChat,
    "com.apple.MobileSMS": .personalChat,
    "ru.keepcoder.Telegram": .personalChat,
    "org.telegram.desktop": .personalChat,
    "com.hnc.Discord": .personalChat,
    "com.facebook.archon": .personalChat,
    "org.whispersystems.signal-desktop": .personalChat,
    // Documents and notes
    "notion.id": .docs,
    "com.microsoft.Word": .docs,
    "com.microsoft.Powerpoint": .docs,
    "com.apple.iWork.Pages": .docs,
    "com.apple.iWork.Keynote": .docs,
    "com.apple.Notes": .docs,
    "com.apple.TextEdit": .docs,
    "md.obsidian": .docs,
    "com.lukilabs.lukiapp": .docs,
    "com.craft.craft": .docs,
    "com.apple.reminders": .docs,
    // Code and AI assistants
    "com.todesktop.230313mzl4w4u92": .code,
    "com.microsoft.VSCode": .code,
    "com.exafunction.windsurf": .code,
    "dev.zed.Zed": .code,
    "com.apple.dt.Xcode": .code,
    "com.apple.Terminal": .code,
    "com.googlecode.iterm2": .code,
    "dev.warp.Warp-Stable": .code,
    "com.mitchellh.ghostty": .code,
    "com.anthropic.claudefordesktop": .code,
    "com.openai.chat": .code,
    "com.openai.codex": .code,
    "com.jetbrains.intellij": .code,
  ]

  private static let browsers: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.apple.Safari",
    "company.thebrowser.Browser",
    "company.thebrowser.dia",
    "com.microsoft.edgemac",
    "org.mozilla.firefox",
    "com.brave.Browser",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
  ]

  /// Window-title rules for browsers and web apps; the first match wins.
  private static let titleRules: [(NSRegularExpression, AppCategory)] = [
    (TextTools.regex("\\b(gmail|outlook|posta in arrivo|inbox|superhuman|hey\\.com|proton mail|fastmail|icloud mail)\\b", ignoreCase: true), .email),
    // Gmail puts the account in the title, "Subject - name@company.com - Gmail"; with Google
    // Workspace the last part is the company's own name, "… - Acme Mail".
    (TextTools.regex("\\s-\\s[^\\s@]+@[\\w.-]+\\.[a-z]{2,}\\s-\\s", ignoreCase: true), .email),
    (TextTools.regex("\\b(slack|microsoft teams|google chat|linear)\\b", ignoreCase: true), .workChat),
    (TextTools.regex("\\b(whatsapp|telegram|messenger|instagram|discord)\\b", ignoreCase: true), .personalChat),
    (
      TextTools.regex(
        "\\b(documenti google|google docs|google slides|presentazioni google|notion|confluence|coda|dropbox paper)\\b",
        ignoreCase: true),
      .docs
    ),
    (TextTools.regex("\\b(claude|chatgpt|gemini|mistral|le chat|github|gitlab|stack overflow|cursor)\\b", ignoreCase: true), .code),
  ]

  private static func byTitle(_ title: String?) -> AppCategory? {
    let title = title ?? ""
    return titleRules.first { TextTools.matches($0.0, title) }?.1
  }

  /// `rules` are the user's (Settings › Style) and come first: apps by bundle identifier,
  /// websites by a word of the window title in browsers and web apps.
  public static func categorize(bundleId: String?, windowTitle: String?, rules: [AppRule] = []) -> AppCategory {
    guard let bundleId else { return .other }
    let web = browsers.contains(bundleId) || bundleId.hasPrefix("com.google.Chrome.app.") || bundleId.hasPrefix("com.apple.Safari.WebApp")
    if let rule = rules.first(where: { $0.kind == .app && $0.value == bundleId }) { return rule.category }
    if web, let title = windowTitle?.lowercased(),
      let rule = rules.first(where: { $0.kind == .website && !$0.value.isEmpty && title.contains($0.value.lowercased()) })
    {
      return rule.category
    }
    if browsers.contains(bundleId) { return byTitle(windowTitle) ?? .other }
    if let category = bundles[bundleId] { return category }
    // Web apps installed from Chrome or Safari ("Add to Dock"): look at the title.
    if web { return byTitle(windowTitle) ?? .other }
    return .other
  }

  /// The user's style for the category (tone, own instructions and learned preferences, composed
  /// by `StylePreferences`), or the default one.
  public static func style(for category: AppCategory, overrides: [String: String] = [:]) -> String {
    if let custom = overrides[category.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
      return String(custom.prefix(2_000))
    }
    return defaultStyles[category] ?? ""
  }

  // MARK: Tones

  /// The categories whose tone the user can choose; code stays literal, other apps neutral.
  public static let adjustable: [AppCategory] = [.email, .workChat, .personalChat, .docs]

  /// The tones offered for each adjustable category, in the order shown. Part of the prompts.
  public static let tones: [AppCategory: [Tone]] = [
    .email: [
      Tone(
        id: "formal",
        style:
          "A formal work email, written rather than spoken. Lay it out as an email: the greeting on its own line, then a blank line; the body in short paragraphs, one per topic, with a blank line between them; the closing on its own line after a blank line, with the name below it if dictated. Formal register: complete, well-built sentences and precise, courteous wording, with no colloquialisms or spoken connectives, keeping the user's \"tu\" or \"Lei\". Don't add greetings, closings or signatures they didn't say."
      ),
      Tone(id: "cordial", style: defaultStyles[.email]!),
      Tone(
        id: "direct",
        style:
          "A short, direct work email, written rather than spoken. Greeting and closing on their own lines only if dictated; one or two short paragraphs that get to the point, without pleasantries or filler. Keep the user's \"tu\" or \"Lei\". Don't add greetings, closings or signatures they didn't say."
      ),
    ],
    .workChat: [
      Tone(
        id: "professional",
        style:
          "Professional and clear, as in a work channel: complete sentences, careful punctuation, courteous without ceremony. Bulleted lists only if the user dictates a list."
      ),
      Tone(id: "direct", style: defaultStyles[.workChat]!),
      Tone(
        id: "informal",
        style:
          "Informal and friendly, as between close colleagues: short sentences, a relaxed tone, no period after a one-line message. Still clear."
      ),
    ],
    .personalChat: [
      Tone(id: "natural", style: defaultStyles[.personalChat]!),
      Tone(
        id: "informal",
        style:
          "Very casual, as in a quick text to a friend: short, relaxed sentences, light punctuation, no final period; a lowercase first letter is fine."
      ),
    ],
    .docs: [
      Tone(id: "polished", style: defaultStyles[.docs]!),
      Tone(id: "notes", style: "Quick notes: terse sentences or bullet points, one idea per line, no filler, keeping every piece of information."),
    ],
  ]

  /// The tone used when the user hasn't chosen one: the category's default style.
  public static let defaultTone: [AppCategory: String] = [.email: "cordial", .workChat: "direct", .personalChat: "natural", .docs: "polished"]
}

/// A tone the user can choose for a category in Settings › Style.
public struct Tone: Sendable, Equatable, Identifiable {
  public let id: String
  /// Part of the prompts, in English like them.
  public let style: String
}

/// An app or a website the user assigned to a category.
public struct AppRule: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable { case app, website }

  public var id: UUID
  public var kind: Kind
  /// The bundle identifier, or a word of the window title.
  public var value: String
  /// What the settings show: the app's name, or the word itself.
  public var name: String
  public var category: AppCategory

  public init(id: UUID = UUID(), kind: Kind, value: String, name: String, category: AppCategory) {
    self.id = id
    self.kind = kind
    self.value = value
    self.name = name
    self.category = category
  }
}

/// Settings › Style: a tone and the user's own instructions per category, and their app rules.
public struct StylePreferences: Codable, Sendable, Equatable {
  /// Tone id per category raw value; missing means the default tone.
  public var tones: [String: String] = [:]
  /// The user's own instructions per category raw value.
  public var instructions: [String: String] = [:]
  public var rules: [AppRule] = []

  public static let maxInstructions = 600

  static let learnedLabel =
    "Learned from the user's own corrections (how to write what they say, never something to add): "
  static let ownLabel = "The user's own instructions, which win over everything else: "

  /// The user's own instructions inside a composed style: the only part that may ask the
  /// cleanup for words the user didn't say, such as a signature.
  static func ownInstructions(in style: String) -> String? {
    guard let range = style.range(of: ownLabel) else { return nil }
    return String(style[range.upperBound...])
  }

  public init(tones: [String: String] = [:], instructions: [String: String] = [:], rules: [AppRule] = []) {
    self.tones = tones
    self.instructions = instructions
    self.rules = rules
  }

  public func tone(for category: AppCategory) -> String? {
    tones[category.rawValue] ?? Categories.defaultTone[category]
  }

  /// The style text of each category that differs from the defaults, as `DictationRequest.styles`
  /// wants it. `learned` holds the preferences learned from the user's corrections, per category.
  public func styles(learned: [String: String] = [:]) -> [String: String] {
    var styles: [String: String] = [:]
    for category in AppCategory.allCases {
      let key = category.rawValue
      let chosen = tones[key].flatMap { id in Categories.tones[category]?.first { $0.id == id } }
      let own = Self.clean(instructions[key])
      let learnedText = Self.clean(learned[key])
      guard chosen != nil || own != nil || learnedText != nil else { continue }
      var parts = [chosen?.style ?? Categories.defaultStyles[category] ?? ""]
      if let learnedText { parts.append("\(Self.learnedLabel)\(learnedText)") }
      if let own { parts.append("\(Self.ownLabel)\(own)") }
      styles[key] = parts.joined(separator: "\n")
    }
    return styles
  }

  private static func clean(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return String(text.prefix(maxInstructions))
  }
}
