import AVFoundation
import Combine
import DiVoiceCore
import DiVoiceEngine
import ServiceManagement
import SwiftUI

/// Permissions, API keys and Verify results; permissions refresh every second while a window is open.
final class SetupModel: ObservableObject {
  enum VerifyRole: String, CaseIterable {
    case transcription, cleanup, scribe
  }

  @Published var microphone = Permissions.microphone
  @Published var accessibility = Permissions.accessibility
  @Published var globe = Permissions.globeKey
  @Published var keyInput: [ProviderID: String] = [:]
  @Published private(set) var savedKeys: [ProviderID: String] = [:]
  @Published private(set) var verifying: Set<VerifyRole> = []
  @Published private(set) var reports: [VerifyRole: [VerifyReport]] = [:]

  let settings: AppSettings
  private var timer: Timer?
  private var observer: NSObjectProtocol?

  /// `previewKeys`: masked keys to show instead of reading the Keychain (screenshots).
  init(settings: AppSettings, previewKeys: [ProviderID: String]? = nil) {
    self.settings = settings
    if let previewKeys {
      savedKeys = previewKeys
      microphone = .authorized
      accessibility = false
      globe = .doNothing
      return
    }
    refreshKeys()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    observer = NotificationCenter.default.addObserver(forName: .diVoiceKeysChanged, object: nil, queue: .main) { [weak self] _ in
      self?.refreshKeys()
    }
  }

  deinit {
    timer?.invalidate()
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  var missingKeys: [ProviderID] {
    guard OrgStore.shared.membership == nil else { return [] }
    return ProviderID.allCases.filter { settings.pipeline.providers.contains($0) && savedKeys[$0] == nil }
  }

  /// The pipeline uses an OpenAI-compatible server whose address is still to add.
  var missingServer: Bool { EngineFactory.missingServer(settings) }

  var isReady: Bool {
    microphone == .authorized && accessibility && missingKeys.isEmpty && !missingServer
  }

  func refresh() {
    microphone = Permissions.microphone
    accessibility = Permissions.accessibility
    globe = Permissions.globeKey
  }

  private func refreshKeys() {
    savedKeys = Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { p in KeyStore.masked(p).map { (p, $0) } })
  }

  func requestMicrophone() {
    if microphone == .notDetermined {
      Permissions.requestMicrophone { [weak self] _ in self?.refresh() }
    } else {
      Permissions.openMicrophoneSettings()
    }
  }

  func requestAccessibility() {
    Permissions.promptAccessibility()
    Permissions.openAccessibilitySettings()
  }

  // MARK: Keys

  /// Saves the typed key and verifies the models that use it.
  func saveKey(_ provider: ProviderID) {
    let value = (keyInput[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, KeyStore.save(value, for: provider) else { return }
    keyInput[provider] = ""
    refreshKeys()
    verifyAll(using: provider)
  }

  func removeKey(_ provider: ProviderID) {
    KeyStore.remove(provider)
    refreshKeys()
  }

  // MARK: Verify

  func verifyAll(using provider: ProviderID? = nil) {
    let pipeline = settings.pipeline
    if provider == nil || pipeline.transcription.provider == provider { verify(.transcription) }
    if provider == nil || pipeline.cleanup.provider == provider { verify(.cleanup) }
    if provider == nil || pipeline.scribe.provider == provider { verify(.scribe) }
  }

  func verify(_ role: VerifyRole) {
    guard !verifying.contains(role) else { return }
    verifying.insert(role)
    reports[role] = nil
    let pipeline = settings.pipeline
    let language = TextTools.normalizeLanguage(settings.language)
    let vocabulary = Vocabulary.bias(OrgStore.shared.vocabulary(personal: VocabularyStore.shared.entries))
    let throughServer = OrgStore.shared.membership != nil
    Task { @MainActor in
      let result: [VerifyReport]
      if throughServer {
        result = await verifyThroughServer(role, language: language, vocabulary: vocabulary)
        reports[role] = result
        verifying.remove(role)
        log(result)
        return
      }
      do {
        switch role {
        case .transcription:
          let service = try EngineFactory.transcription(pipeline.transcription)
          let pcm = try await SpeechSample.pcm(language: language ?? "en", sampleRate: pipeline.transcription.provider.sampleRate)
          result = await Verifier.transcription(pipeline.transcription, service: service, pcm: pcm, language: language, vocabulary: vocabulary)
        case .cleanup:
          let report = await Verifier.chat(pipeline.cleanup, step: .cleanup, chat: try EngineFactory.chat(pipeline.cleanup))
          if report.predictionAccepted == false { settings.pipeline.cleanup.prediction = false }
          result = [report]
        case .scribe:
          result = [await Verifier.chat(pipeline.scribe, step: .scribe, chat: try EngineFactory.chat(pipeline.scribe))]
        }
      } catch {
        let model = role == .transcription ? pipeline.transcription.batchModel : (role == .cleanup ? pipeline.cleanup.model : pipeline.scribe.model)
        result = [VerifyReport(step: role == .scribe ? .scribe : (role == .cleanup ? .cleanup : .batch), model: model, ok: false, detail: error.localizedDescription)]
      }
      reports[role] = result
      verifying.remove(role)
      log(result)
    }
  }

  /// Verify through the organization's server: the same path as a dictation, not counted in the statistics.
  @MainActor
  private func verifyThroughServer(_ role: VerifyRole, language: String?, vocabulary: [String]) async -> [VerifyReport] {
    let sessionId = UUID().uuidString.lowercased()
    var model = ""
    do {
      guard let prepared = try EngineFactory.verifyServices(sessionId: sessionId) else { return [] }
      defer { Task { await prepared.relay.close() } }
      let pipeline = prepared.pipeline
      switch role {
      case .transcription:
        model = pipeline.transcription.realtimeModel
        let pcm = try await SpeechSample.pcm(language: language ?? "en", sampleRate: pipeline.transcription.provider.sampleRate)
        return await Verifier.transcription(
          pipeline.transcription, service: prepared.services.transcription, pcm: pcm, language: language, vocabulary: vocabulary,
          includeBatch: false)
      case .cleanup, .scribe:
        model = role == .cleanup ? pipeline.cleanup.model : pipeline.scribe.model
        await prepared.relay.start(sessionId: sessionId, sampleRate: nil, language: nil, vocabulary: [], purpose: .verify)
        return role == .cleanup
          ? [await Verifier.chat(pipeline.cleanup, step: .cleanup, chat: prepared.services.cleanup)]
          : [await Verifier.chat(pipeline.scribe, step: .scribe, chat: prepared.services.scribe)]
      }
    } catch {
      return [VerifyReport(step: role == .scribe ? .scribe : (role == .cleanup ? .cleanup : .streaming), model: model, ok: false, detail: error.localizedDescription)]
    }
  }

  private func log(_ result: [VerifyReport]) {
    for report in result {
      let ms = [report.connectMs.map { "connect \(Int($0))" }, report.firstTokenMs.map { "first token \(Int($0))" }, report.totalMs.map { "total \(Int($0))" }]
        .compactMap { $0 }.joined(separator: ", ")
      appLog.notice("Verify \(report.step.rawValue, privacy: .public) \(report.model, privacy: .public): \(report.ok ? "ok" : "error", privacy: .public) [\(ms, privacy: .public) ms] \(String(report.detail.prefix(160)), privacy: .public)")
    }
  }
}

// MARK: - Building blocks

/// Done, to do, or needs attention: a round badge.
struct StatusBadge: View {
  let ok: Bool
  var warning = false

  var body: some View {
    ZStack {
      Circle().fill(ok ? Theme.positive.opacity(0.14) : (warning ? Theme.accent.opacity(0.16) : Theme.fill))
      Image(systemName: ok ? "checkmark" : (warning ? "exclamationmark" : "circle.dotted"))
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(ok ? Theme.positive : (warning ? Theme.accent : Color.secondary))
    }
    .frame(width: 26, height: 26)
  }
}

/// A step of the first launch, as a card.
struct SetupStep<Accessory: View>: View {
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
  let ok: Bool
  var warning = false
  @ViewBuilder let accessory: () -> Accessory

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      StatusBadge(ok: ok, warning: warning)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        accessory()
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .card()
  }
}

/// Saved key (masked) or a field to paste a new one.
struct KeyField: View {
  @ObservedObject var model: SetupModel
  let provider: ProviderID

  /// Where the provider's keys are created; an OpenAI-compatible server has its own.
  private var keysPage: URL? {
    switch provider {
    case .mistral: URL(string: "https://console.mistral.ai/api-keys")!
    case .openai: URL(string: "https://platform.openai.com/api-keys")!
    case .elevenlabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")!
    case .compatible: nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let saved = model.savedKeys[provider] {
        HStack {
          Pill(verbatim: saved, icon: "key.fill")
          Spacer()
          Button("Replace") { model.removeKey(provider) }.buttonStyle(.secondary)
        }
      } else {
        HStack {
          SecureField(
            "", text: Binding(get: { model.keyInput[provider] ?? "" }, set: { model.keyInput[provider] = $0 }),
            prompt: Text("Paste the \(provider.displayName) API key")
          )
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .onSubmit { model.saveKey(provider) }
          Button("Save") { model.saveKey(provider) }
            .buttonStyle(.primary)
            .disabled((model.keyInput[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let keysPage {
          Link("Create a key on \(keysPage.host ?? "")", destination: keysPage).font(.system(size: 11.5))
        } else {
          Text("The key of your server. If it doesn't ask for one, type any word.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// The address of the OpenAI-compatible server for cleanup and Scribe.
struct CompatibleServerField: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField("", text: $settings.compatibleBaseURL, prompt: Text(verbatim: "http://localhost:4000"))
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12).monospaced())
        .labelsHidden()
        .autocorrectionDisabled()
      if !settings.compatibleBaseURL.trimmingCharacters(in: .whitespaces).isEmpty, settings.compatibleServer == nil {
        Text("This doesn't look like a server address.").font(.system(size: 11.5)).foregroundStyle(Theme.accent)
      }
    }
  }
}

/// The results of the Verify button for one role.
struct VerifyResults: View {
  @ObservedObject var model: SetupModel
  let role: SetupModel.VerifyRole

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          model.verify(role)
        } label: {
          Label("Verify", systemImage: "checkmark.seal")
        }
        .buttonStyle(.secondary)
        .disabled(model.verifying.contains(role))
        if model.verifying.contains(role) { ProgressView().controlSize(.small) }
      }
      ForEach(model.reports[role] ?? []) { report in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Pill(verbatim: label(report.step), icon: report.ok ? "checkmark" : "xmark", tint: report.ok ? Theme.positive : Theme.accent)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(report.model) · \(timings(report))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            Text(report.detail).font(.system(size: 11.5)).foregroundStyle(report.ok ? Color.secondary : Theme.accent).lineLimit(2)
            if report.predictionAccepted == false {
              Text("This model doesn't accept predicted outputs: turned off.").font(.system(size: 11.5)).foregroundStyle(Theme.accent)
            }
          }
        }
      }
    }
  }

  private func label(_ step: VerifyReport.Step) -> String {
    switch step {
    case .streaming: String(localized: "Streaming")
    case .batch: String(localized: "File")
    case .cleanup: String(localized: "Cleanup")
    case .scribe: String(localized: "Scribe")
    }
  }

  private func timings(_ report: VerifyReport) -> String {
    var parts: [String] = []
    if let connect = report.connectMs { parts.append(String(localized: "connection \(String(Int(connect))) ms")) }
    if let first = report.firstTokenMs { parts.append(String(localized: "first token \(String(Int(first))) ms")) }
    if let total = report.totalMs { parts.append(String(localized: "total \(String(Int(total))) ms")) }
    return parts.joined(separator: " · ")
  }
}

/// A model id: pick a known one or type any other.
struct ModelField: View {
  let title: LocalizedStringKey
  @Binding var model: String
  let suggestions: [ModelInfo]

  var body: some View {
    CardRow(title) {
      HStack(spacing: 6) {
        TextField("", text: $model).textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced()).frame(width: 260)
        // An OpenAI-compatible server has its own models: the name is typed by hand.
        if !suggestions.isEmpty {
          Menu {
            ForEach(suggestions) { info in
              Button(info.name) { model = info.id }
            }
          } label: {
            Image(systemName: "chevron.up.chevron.down")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
        }
      }
    }
  }
}

// MARK: - First launch

/// First launch: personal (provider and key) or team (invite), permissions, Globe key.
struct OnboardingView: View {
  enum Usage { case personal, team }

  @ObservedObject var model: SetupModel
  @ObservedObject var settings: AppSettings
  @ObservedObject var org = OrgStore.shared
  let onInvite: (InviteLink) -> Void
  let onCreate: () -> Void
  let onDone: () -> Void
  @State private var usage: Usage

  init(
    model: SetupModel, settings: AppSettings, usage: Usage = .personal, onInvite: @escaping (InviteLink) -> Void,
    onCreate: @escaping () -> Void = {}, onDone: @escaping () -> Void
  ) {
    self.model = model
    self.settings = settings
    self.onInvite = onInvite
    self.onCreate = onCreate
    self.onDone = onDone
    _usage = State(initialValue: usage)
  }

  /// The provider for cleanup and Scribe. Choosing one that also transcribes uses it for everything;
  /// an OpenAI-compatible server leaves the transcription as it is.
  private var provider: Binding<ProviderID> {
    Binding(
      get: { settings.pipeline.cleanup.provider },
      set: { $0.supportsTranscription ? settings.useProvider($0) : settings.useChatProvider($0) })
  }

  private var transcriptionProvider: Binding<ProviderID> {
    Binding(get: { settings.pipeline.transcription.provider }, set: { settings.pipeline.transcription = .defaults($0) })
  }

  /// One model for cleanup and Scribe on the OpenAI-compatible server; each can change later in Settings › Models.
  private var compatibleModel: Binding<String> {
    Binding(
      get: { settings.pipeline.cleanup.model },
      set: {
        var pipeline = settings.pipeline
        pipeline.cleanup.model = $0
        pipeline.scribe.model = $0
        settings.pipeline = pipeline
      })
  }

  private var usesCompatible: Bool { settings.pipeline.cleanup.provider == .compatible }

  private var canStart: Bool { model.isReady && (org.membership != nil || usage == .personal) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Pill("diVoice", icon: "waveform")
          Text("Set up diVoice").font(.system(size: 24, weight: .bold))
          Text("Hold Fn to dictate, Ctrl+Fn for Scribe.").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)

        if let membership = org.membership {
          SetupStep(
            title: "Organization",
            detail: "Connected to \(membership.orgName) (\(membership.host)): its server holds the AI keys and chooses the models.",
            ok: true
          ) { EmptyView() }
        } else {
          SetupStep(title: "How will you use diVoice?", detail: "On your own, with your own AI key; or with your team, through your organization's server.", ok: true) {
            PillPicker(selection: $usage, options: [(.personal, "With my own API key"), (.team, "With my team")])
              .padding(.top, 2)
          }
          if usage == .team {
            SetupStep(title: "Invite link", detail: "Paste the link your admin sent you.", ok: false) {
              VStack(alignment: .leading, spacing: 10) {
                PasteInviteView(onLink: onInvite)
                HStack {
                  Text("Setting up diVoice for your team?").font(.system(size: 12.5)).foregroundStyle(.secondary)
                  Button("Create an organization…") { onCreate() }.buttonStyle(.secondary)
                }
              }
            }
          } else {
            personalSteps
          }
        }

        permissionSteps

        HStack {
          Spacer()
          Button(canStart ? "Start" : "Continue later") { onDone() }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
      }
      .padding(.horizontal, 28)
      .padding(.top, 36)
      .padding(.bottom, 24)
    }
    .frame(width: 600, height: 700)
    .background(Theme.background)
    .tint(Theme.selected)
  }

  @ViewBuilder private var personalSteps: some View {
    SetupStep(
      title: "AI provider",
      detail: "Your voice goes straight to the provider you choose. You can change models for each step later in Settings › Models.", ok: true
    ) {
      PillPicker(selection: provider, options: ProviderID.chatProviders.map { ($0, LocalizedStringKey($0.displayName)) })
        .padding(.top, 2)
    }

    SetupStep(
      title: "Transcription",
      detail: "The provider that turns your voice into text. ElevenLabs only transcribes: the AI provider above writes the clean text.",
      ok: true
    ) {
      PillPicker(
        selection: transcriptionProvider, options: ProviderID.transcriptionProviders.map { ($0, LocalizedStringKey($0.displayName)) }
      )
      .padding(.top, 2)
    }

    if usesCompatible {
      SetupStep(
        title: "OpenAI-compatible server",
        detail: "The address of your LiteLLM, Ollama or other OpenAI-compatible server, and the model it should use for cleanup and Scribe.",
        ok: !model.missingServer && !settings.pipeline.cleanup.model.isEmpty && !settings.pipeline.scribe.model.isEmpty
      ) {
        CompatibleServerField(settings: settings)
        TextField("", text: compatibleModel, prompt: Text("Model name"))
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12).monospaced())
          .labelsHidden()
          .autocorrectionDisabled()
      }
    }

    SetupStep(
      title: settings.pipeline.providers.count > 1 ? "API keys" : "API key",
      detail: "Saved in this Mac's Keychain and sent only to the provider.",
      ok: model.missingKeys.isEmpty
    ) {
      ForEach(ProviderID.allCases.filter(settings.pipeline.providers.contains)) { provider in
        KeyField(model: model, provider: provider)
      }
      if model.missingKeys.isEmpty {
        VerifyResults(model: model, role: .transcription)
        if usesCompatible, !model.missingServer { VerifyResults(model: model, role: .cleanup) }
      }
    }
  }

  @ViewBuilder private var permissionSteps: some View {
    SetupStep(title: "Microphone", detail: "diVoice listens only while you hold the key.", ok: model.microphone == .authorized) {
      if model.microphone != .authorized {
        Button(model.microphone == .notDetermined ? "Allow the microphone" : "Open Settings") { model.requestMicrophone() }
          .buttonStyle(.secondary)
      }
    }

    SetupStep(
      title: "Accessibility",
      detail: "Needed to detect the Fn key and to insert the text in the active app. Turn diVoice on in the list.",
      ok: model.accessibility
    ) {
      if !model.accessibility {
        Button("Open Accessibility settings") { model.requestAccessibility() }.buttonStyle(.secondary)
      }
    }

    SetupStep(
      title: "🌐 / Fn key",
      detail: model.globe.isCompatible
        ? "Set to “Do Nothing”."
        : "It's set to “\(model.globe.label)”. In Settings › Keyboard choose “Press 🌐 key to: Do Nothing”, otherwise macOS opens emoji or dictation together with diVoice.",
      ok: model.globe.isCompatible,
      warning: !model.globe.isCompatible
    ) {
      if !model.globe.isCompatible {
        Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }.buttonStyle(.secondary)
      }
    }
  }
}

// MARK: - Settings

struct SettingsView: View {
  enum Page: Hashable {
    case general, models, style, dictionary, history, statistics, team, organization, latency
  }

  @ObservedObject var settings: AppSettings
  @ObservedObject var setup: SetupModel
  @ObservedObject var history: HistoryStore
  @ObservedObject var org = OrgStore.shared
  @State var page: Page = .general
  /// The stores the Dictionary and Statistics pages show (sample ones for the screenshots).
  var vocabulary: VocabularyStore = .shared
  var stats: StatsStore = .shared
  @Environment(\.teamPreview) private var teamPreview
  @Environment(\.stylePreview) private var stylePreview
  @Environment(\.learningPreview) private var learningPreview
  @Environment(\.adminPreview) private var adminPreview
  @State private var microphones = AudioDevices.inputDevices()
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

  private var pages: [(page: Page, title: LocalizedStringKey, icon: String)] {
    var pages: [(Page, LocalizedStringKey, String)] = [
      (.general, "General", "gearshape"),
      (.models, "Models", "cpu"),
      (.style, "Style", "textformat"),
      (.dictionary, "Dictionary", "character.book.closed"),
      (.history, "History", "clock.arrow.circlepath"),
    ]
    if org.membership != nil {
      pages += [(.team, "Team", "person.3"), (.organization, "Organization", "building.2")]
    } else {
      pages.append((.statistics, "Statistics", "chart.bar"))
    }
    pages.append((.latency, "Latency", "stopwatch"))
    return pages
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      VStack(alignment: .leading, spacing: 0) {
        let current = pages.first { $0.page == page } ?? pages[0]
        HStack(spacing: 8) {
          Image(systemName: current.icon).font(.system(size: 13))
          Text(current.title).font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 4)
        content
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Theme.background)
    }
    .frame(width: 860, height: 640)
    .tint(Theme.selected)
    .onReceive(NotificationCenter.default.publisher(for: .diVoiceShowSettingsPage)) { note in
      if let target = note.object as? Page { page = target }
    }
    .onChange(of: org.membership == nil) { _, personal in
      if personal, page == .team || page == .organization { page = .statistics }
      if !personal, page == .statistics { page = .team }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 4) {
      Pill("diVoice", icon: "waveform", tint: .primary)
        .padding(.bottom, 14)
      ForEach(pages, id: \.page) { item in
        let selected = item.page == page
        Button {
          page = item.page
        } label: {
          HStack(spacing: 10) {
            Image(systemName: item.icon).frame(width: 18)
            Text(item.title)
            Spacer()
          }
          .font(.system(size: 13, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? Color.primary : Color.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background {
            if selected {
              RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Spacer()
      if let membership = org.membership {
        Pill(verbatim: membership.orgName, icon: "building.2")
      } else {
        Pill("Personal", icon: "person")
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 40)
    .padding(.bottom, 16)
    .frame(width: 200)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Theme.sidebar)
  }

  @ViewBuilder private var content: some View {
    switch page {
    case .general: general
    case .models: ModelsView(settings: settings, setup: setup)
    case .style: StyleView(settings: settings, preview: stylePreview, learning: learningPreview)
    case .dictionary: DictionaryView(store: vocabulary)
    case .history: HistoryView(history: history)
    case .statistics: StatsView(store: stats, settings: settings)
    case .team: TeamView(org: org, settings: settings, preview: teamPreview)
    case .organization:
      if let membership = org.membership { OrganizationView(org: org, membership: membership, preview: adminPreview) }
    case .latency: latency
    }
  }

  private func languageName(_ code: String) -> String {
    code == "auto" ? String(localized: "Automatic detection") : (Locale.current.localizedString(forLanguageCode: code) ?? code).capitalized
  }

  private var general: some View {
    CardPage {
      CardSection("Shortcuts") {
        CardRow("Hold Fn to dictate", detail: "Ctrl+Fn starts Scribe.") {
          Toggle("", isOn: $settings.fnEnabled).toggleStyle(.pill).labelsHidden()
        }
        Divider()
        CardRow(
          "Alternative key for external keyboards",
          detail: "With the alternative key, Ctrl + key starts Scribe. On some layouts right ⌥ types characters like @ and #."
        ) {
          Picker("", selection: $settings.alternativeTrigger) {
            Text("Right ⌘").tag("rightCommand")
            Text("Right ⌥").tag("rightOption")
            Text("None").tag("none")
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      CardSection("Dictation") {
        CardRow("Language") {
          Picker("", selection: $settings.language) {
            ForEach(AppSettings.languages, id: \.self) { Text(languageName($0)).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
        Divider()
        CardRow("Microphone") {
          Picker("", selection: $settings.microphoneUID) {
            Text("System microphone").tag("")
            ForEach(microphones) { device in Text(device.name).tag(device.uid) }
          }
          .labelsHidden()
          .fixedSize()
        }
        Divider()
        CardRow(
          "Keep the microphone ready",
          detail: "So the first words are never cut. Between dictations the microphone stays on and only the last half second is kept in memory, then added to the start of your next dictation. Nothing leaves your Mac until you press the key. macOS shows the microphone indicator. Not with Bluetooth headsets: it would lower their sound."
        ) {
          Toggle("", isOn: $settings.keepMicrophoneReady).toggleStyle(.pill).labelsHidden()
        }
        Divider()
        CardRow("Start and end sounds") {
          Toggle("", isOn: $settings.playSounds).toggleStyle(.pill).labelsHidden()
        }
        Divider()
        CardRow("Restore the clipboard after inserting") {
          Toggle("", isOn: $settings.restoreClipboard).toggleStyle(.pill).labelsHidden()
        }
        Divider()
        CardRow(
          "Use the text on screen as context",
          detail: "When you start dictating, diVoice reads the conversation and the text around the cursor, to spell names and match the tone. It goes only to the AI provider and is never saved. Never in password fields."
        ) {
          Toggle("", isOn: $settings.useScreenContext).toggleStyle(.pill).labelsHidden()
        }
      }
      CardSection("Overlay") {
        CardRow("Position", detail: "Drag the overlay while you dictate to move it: diVoice remembers where you put it.") {
          Button("Reset position") { OverlayPosition.reset() }.buttonStyle(.secondary)
        }
      }
      CardSection("System") {
        CardRow("Open diVoice at login") {
          Toggle("", isOn: $launchAtLogin).toggleStyle(.pill).labelsHidden()
            .onChange(of: launchAtLogin) { _, enabled in
              do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
              } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
              }
            }
        }
        Divider()
        CardRow("Microphone") { StatusPill(ok: setup.microphone == .authorized) }
        Divider()
        CardRow("Accessibility") { StatusPill(ok: setup.accessibility) }
        Divider()
        CardRow("🌐 key: \(setup.globe.label)") { StatusPill(ok: setup.globe.isCompatible, warning: !setup.globe.isCompatible) }
      }
    }
    .onAppear { microphones = AudioDevices.inputDevices() }
  }

  private var latency: some View {
    let stats = history.latency
    let recent = Array(history.entries.prefix(12))
    return CardPage {
      HStack(spacing: 12) {
        StatTile(title: "Median (p50)", value: Format.seconds(stats.p50))
        StatTile(title: "p95", value: Format.seconds(stats.p95))
        StatTile(title: "Dictations", value: "\(stats.count)")
      }
      Text("From releasing the key to the text read by the target app. Target: about 1 s.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
      CardSection("Recent dictations") {
        Table(recent) {
          TableColumn("Total") { Text(Format.seconds($0.totalMs)).monospacedDigit() }.width(70)
          TableColumn("Transcr.") { Text(Format.seconds($0.pipelineTimings["transcribeMs"])).monospacedDigit() }.width(70)
          TableColumn("Cleanup") { Text(Format.seconds($0.pipelineTimings["cleanupMs"] ?? $0.pipelineTimings["scribeMs"])).monospacedDigit() }.width(70)
          TableColumn("Path") { Text("\($0.transcription)/\($0.cleanup)").font(.caption) }.width(130)
          // Characters of context read on screen: shows where it works (Gmail, Slack...).
          TableColumn("Context") { entry in
            Text(verbatim: entry.clientTimings["screenChars"].map { $0 > 0 ? Int($0).formatted() : "—" } ?? "—").font(.caption).monospacedDigit()
          }.width(60)
          TableColumn("App") { Text($0.appName ?? "—").font(.caption) }
        }
        .scrollContentBackground(.hidden)
        .frame(minHeight: 300)
      }
    }
  }
}

/// Keys, and provider and model for each step of the pipeline. With an organization, its
/// models (chosen by the admin) instead.
struct ModelsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var setup: SetupModel
  @ObservedObject var org = OrgStore.shared

  var body: some View {
    if let membership = org.membership {
      OrganizationModelsView(membership: membership, setup: setup)
    } else {
      CardPage {
        CardSection("API keys") {
          ForEach(ProviderID.allCases) { provider in
            CardRow(LocalizedStringKey(provider.displayName), detail: keyDetail(provider).map { LocalizedStringKey($0) }) {
              KeyField(model: setup, provider: provider).frame(width: 380)
            }
            if provider == .compatible {
              CardRow("Server address", detail: "LiteLLM, Ollama or any other server with OpenAI's chat completions API.") {
                CompatibleServerField(settings: settings).frame(width: 380)
              }
            }
            if provider != ProviderID.allCases.last { Divider() }
          }
          Text("Keys stay in this Mac's Keychain and are sent only to their provider.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        PipelineSections(pipeline: $settings.pipeline, setup: setup)
        HStack {
          ForEach(ProviderID.fullProviders) { provider in
            Button("Use \(provider.displayName) for everything") { settings.useProvider(provider) }.buttonStyle(.secondary)
          }
        }
      }
    }
  }
}

extension ModelsView {
  /// What a provider that doesn't run the whole pipeline is for.
  fileprivate func keyDetail(_ provider: ProviderID) -> String? {
    if !provider.supportsChat { return String(localized: "Transcription only") }
    if !provider.supportsTranscription { return String(localized: "Cleanup and Scribe only") }
    return nil
  }
}

/// Transcription, cleanup and Scribe: provider and models, with Verify when `setup` is given.
struct PipelineSections: View {
  @Binding var pipeline: PipelineSettings
  var setup: SetupModel?
  /// Providers the transcription can use (an organization's server supports fewer).
  var transcriptionProviders = ProviderID.transcriptionProviders
  /// Providers for cleanup and Scribe, which need chat models: not ElevenLabs, and through an
  /// organization's server not an OpenAI-compatible server either.
  var chatProviders = ProviderID.chatProviders

  private func providerPicker(_ selection: Binding<ProviderID>, _ providers: [ProviderID]) -> some View {
    CardRow("Provider") {
      PillPicker(selection: selection, options: providers.map { ($0, LocalizedStringKey($0.displayName)) })
    }
  }

  var body: some View {
    CardSection("Transcription") {
      providerPicker(
        Binding(get: { pipeline.transcription.provider }, set: { pipeline.transcription = .defaults($0) }), transcriptionProviders)
      CardRow("Mode") {
        Picker("", selection: $pipeline.transcription.mode) {
          Text("Hybrid: streaming while you speak, file at the end").tag(TranscriptionMode.hybrid)
          Text("Streaming").tag(TranscriptionMode.realtime)
          Text("File at the end").tag(TranscriptionMode.batch)
        }
        .labelsHidden()
        .fixedSize()
      }
      if pipeline.transcription.mode != .batch {
        ModelField(
          title: "Streaming model", model: $pipeline.transcription.realtimeModel,
          suggestions: ModelCatalog.transcriptionModels(pipeline.transcription.provider, realtime: true))
      }
      ModelField(
        title: "File model", model: $pipeline.transcription.batchModel,
        suggestions: ModelCatalog.transcriptionModels(pipeline.transcription.provider, realtime: false))
      if let setup { VerifyResults(model: setup, role: .transcription) }
    }

    CardSection("Cleanup") {
      providerPicker(Binding(get: { pipeline.cleanup.provider }, set: { pipeline.cleanup = .cleanupDefaults($0) }), chatProviders)
      ModelField(title: "Model", model: $pipeline.cleanup.model, suggestions: ModelCatalog.chatModels(pipeline.cleanup.provider))
      let caps = ModelCatalog.chatCapabilities(pipeline.cleanup.provider, pipeline.cleanup.model)
      if caps.prediction {
        CardRow("Predicted outputs", detail: "Faster when the text barely changes.") {
          Toggle("", isOn: $pipeline.cleanup.prediction).toggleStyle(.pill).labelsHidden()
        }
      }
      if caps.fastTier {
        CardRow(
          "Fast processing",
          detail: "About half a second faster per dictation. Cleanup costs about twice as much, still only a few hundred tokens per dictation."
        ) {
          Toggle("", isOn: $pipeline.cleanup.fastTier).toggleStyle(.pill).labelsHidden()
        }
      }
      if let setup { VerifyResults(model: setup, role: .cleanup) }
    }

    CardSection("Scribe") {
      providerPicker(Binding(get: { pipeline.scribe.provider }, set: { pipeline.scribe = .scribeDefaults($0) }), chatProviders)
      ModelField(title: "Model", model: $pipeline.scribe.model, suggestions: ModelCatalog.chatModels(pipeline.scribe.provider))
      if let setup { VerifyResults(model: setup, role: .scribe) }
    }
  }
}

/// A member's view of the organization's models: read-only, with Verify.
struct OrganizationModelsView: View {
  let membership: Membership
  @ObservedObject var setup: SetupModel

  private func describe(_ provider: ProviderID, _ model: String) -> String {
    "\(provider.displayName) · \(model)"
  }

  var body: some View {
    let pipeline = membership.pipeline
    CardPage {
      Text(
        membership.isAdmin
          ? "\(membership.orgName) chooses the models for everyone. Change them in the Organization tab."
          : "\(membership.orgName) chooses the models for everyone, and its server holds the keys: there's nothing to set up here."
      )
      .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      CardSection("Transcription") {
        CardRow("Model") {
          Pill(
            verbatim: describe(
              pipeline.transcription.provider,
              pipeline.transcription.mode == .realtime ? pipeline.transcription.realtimeModel : pipeline.transcription.batchModel), icon: "waveform")
        }
        VerifyResults(model: setup, role: .transcription)
      }
      CardSection("Cleanup") {
        CardRow("Model") { Pill(verbatim: describe(pipeline.cleanup.provider, pipeline.cleanup.model), icon: "text.badge.checkmark") }
        VerifyResults(model: setup, role: .cleanup)
      }
      CardSection("Scribe") {
        CardRow("Model") { Pill(verbatim: describe(pipeline.scribe.provider, pipeline.scribe.model), icon: "sparkles") }
        VerifyResults(model: setup, role: .scribe)
      }
    }
  }
}

/// The app's windows (it otherwise lives only in the menu bar): the warm background runs
/// under a transparent title bar.
final class WindowManager {
  private var windows: [String: NSWindow] = [:]

  func show<Content: View>(_ id: String, title: String, @ViewBuilder content: () -> Content) {
    if let window = windows[id] {
      present(window)
      return
    }
    let window = NSWindow(contentViewController: NSHostingController(rootView: content().ignoresSafeArea()))
    window.title = title
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.center()
    windows[id] = window
    present(window)
  }

  func close(_ id: String) {
    windows[id]?.close()
    windows[id] = nil
  }

  private func present(_ window: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}
