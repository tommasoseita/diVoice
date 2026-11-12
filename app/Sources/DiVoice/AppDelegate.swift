import AppKit
import Combine
import DiVoiceCore
import DiVoiceEngine
import DiVoiceKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let settings = AppSettings.shared
  private let history = HistoryStore.shared
  private let windows = WindowManager()
  private var overlay: OverlayController!
  private var controller: DictationController!
  private var hotkeys: HotkeyMonitor!
  private var statusItem: StatusItemController!
  private var updater: Updater!
  private var setupModel: SetupModel?
  private var accessibilityTimer: Timer?
  private var orgTimer: Timer?
  private var cancellables = Set<AnyCancellable>()
  /// Between the system's "locked" and "unlocked" notifications.
  private var screenLocked = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Without a main menu, ⌘V, ⌘C, ⌘A and ⌘Z don't reach text fields.
    NSApp.mainMenu = MainMenu.make()
    logLaunch()
    // An invite recorded on the download comes first, even when opened from the disk image:
    // after joining, diVoice moves itself to Applications.
    let org = OrgStore.shared
    let downloadedInvite = org.membership == nil ? InviteDetector.fromDiskImages().flatMap { InviteDetector.isHandled($0) ? nil : $0 } : nil
    if let downloadedInvite {
      appLog.notice("Invite found in the disk image's name, from \(downloadedInvite.server.host ?? "?", privacy: .public)")
    } else if InstallLocation.warnIfNeeded() {
      NSApp.terminate(nil)
      return
    }
    updater = Updater(settings: settings)
    overlay = OverlayController()
    controller = DictationController(settings: settings, overlay: overlay, history: history)
    hotkeys = HotkeyMonitor(triggers: settings.triggers)
    statusItem = StatusItemController(history: history)

    hotkeys.onAction = { [weak self] action in self?.controller.handle(action) }
    hotkeys.onReset = { [weak self] in self?.controller.handle(.cancel(.otherKey)) }
    // On the hotkey thread, before the app gets the key: the controller reads the field quickly.
    let controller = self.controller!
    hotkeys.onReturn = { controller.returnPressed() }
    controller.onRecordingChange = { [weak self] recording in self?.statusItem.setRecording(recording) }
    controller.onNeedsSetup = { [weak self] in self?.showSetup() }
    StatsStore.shared.importHistoryIfNeeded(history.entries)
    controller.onDictation = { output in StatsStore.shared.record(words: output.words, audioMs: output.audioMs) }
    statusItem.onPasteLast = { [weak self] in self?.controller.pasteLast() }
    statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
    statusItem.onOpenHistory = { [weak self] in self?.showSettings(page: .history) }
    statusItem.onOpenSetup = { [weak self] in self?.showSetup() }
    statusItem.statusLine = { [weak self] in self?.statusLine() ?? "diVoice" }
    statusItem.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
    statusItem.canCheckForUpdates = { [weak self] in self?.updater.canCheckForUpdates ?? false }

    // The transcription provider decides the audio sample rate: the microphone is prepared again.
    settings.$pipeline
      .map(\.transcription.provider)
      .removeDuplicates()
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.controller.prepareMicrophone() }
      .store(in: &cancellables)

    // Joining or leaving an organization can change the microphone's sample rate.
    NotificationCenter.default.publisher(for: .diVoiceOrganizationChanged)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.controller.prepareMicrophone() }
      .store(in: &cancellables)
    // Another microphone, Keep the microphone ready turned on or off, or the permission just given.
    Publishers.Merge(settings.$microphoneUID.removeDuplicates().map { _ in () }, settings.$keepMicrophoneReady.removeDuplicates().map { _ in () })
      .dropFirst(2)
      .merge(with: NotificationCenter.default.publisher(for: .diVoiceMicrophoneAllowed).map { _ in () })
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.controller.prepareMicrophone() }
      .store(in: &cancellables)
    observeSleep()
    org.$notice
      .compactMap { $0 }
      .receive(on: DispatchQueue.main)
      .sink { message in
        org.notice = nil
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
      }
      .store(in: &cancellables)
    Task { await org.refresh() }
    orgTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in Task { await OrgStore.shared.refresh() } }

    // Shortcuts changed from the settings.
    settings.$fnEnabled.combineLatest(settings.$alternativeTrigger)
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        self.hotkeys.setTriggers(self.settings.triggers)
      }
      .store(in: &cancellables)

    startHotkeysWhenTrusted()
    if let downloadedInvite {
      showJoin(downloadedInvite)
    } else if needsSetup {
      showSetup()
    }
  }

  /// divoice://join links, from the invite page's "Open diVoice" button.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let link = urls.lazy.compactMap({ InviteLink.parse($0) }).first else { return }
    showJoin(link)
  }

  private func showJoin(_ link: InviteLink) {
    if let membership = OrgStore.shared.membership {
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      if membership.server == link.server {
        alert.messageText = String(localized: "You're already a member of \(membership.orgName)")
      } else {
        alert.messageText = String(localized: "You're a member of \(membership.orgName)")
        alert.informativeText = String(localized: "To join another organization, first leave this one in Settings › Organization.")
      }
      alert.runModal()
      return
    }
    let model = JoinModel(link: link)
    windows.close("join")
    windows.show("join", title: "diVoice") {
      JoinView(
        model: model,
        onJoined: { [weak self] in
          self?.windows.close("join")
          self?.afterJoin()
        },
        onCancel: { [weak self] in
          InviteDetector.markHandled(link)
          self?.windows.close("join")
          if self?.needsSetup == true { self?.showSetup() }
        })
    }
  }

  /// Opened from the disk image: diVoice moves itself to Applications and opens again there.
  /// A new organization on the user's Cloudflare account, with them as its first admin.
  private func showCreateOrganization() {
    if OrgStore.shared.membership != nil { return }
    windows.show("create-org", title: "diVoice") {
      CreateOrgView(
        model: CreateOrgModel(),
        onCreated: { [weak self] in
          self?.windows.close("create-org")
          self?.afterJoin()
        },
        onCancel: { [weak self] in self?.windows.close("create-org") })
    }
  }

  /// While the Mac sleeps, its screen is off or it's locked, nobody dictates: a microphone kept
  /// ready goes off, and comes back on afterwards (not at a locked screen).
  private func observeSleep() {
    let workspace = NSWorkspace.shared.notificationCenter
    let off: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
    let on: [Notification.Name] = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
    for name in off {
      workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.controller.pauseMicrophone() }
    }
    for name in on {
      workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self, !self.screenLocked else { return }
        self.controller.prepareMicrophone()
      }
    }
    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      self?.screenLocked = true
      self?.controller.pauseMicrophone()
    }
    distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
      self?.screenLocked = false
      self?.controller.prepareMicrophone()
    }
  }

  private func afterJoin() {
    if InstallLocation.problem != nil, InstallLocation.moveToApplications() { return }
    controller.prepareMicrophone()
    windows.close("setup")
    showSetup()
  }

  /// One line in the system log at every launch: version, path, permissions and how long
  /// reading the keys from the Keychain takes (a password prompt would block it).
  ///   log show --last 1h --predicate 'subsystem == "app.wibo.divoice"' --info
  private func logLaunch() {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    let started = MonotonicClock.nowNs()
    let keys = ProviderID.allCases.filter { KeyStore.hasKey($0) }.map(\.rawValue).joined(separator: ",")
    let keychainMs = Double(MonotonicClock.nowNs() - started) / 1_000_000
    let microphone: String
    switch Permissions.microphone {
    case .authorized: microphone = "granted"
    case .denied: microphone = "denied"
    case .restricted: microphone = "restricted"
    case .notDetermined: microphone = "not determined"
    @unknown default: microphone = "unknown"
    }
    appLog.notice("""
    Launch diVoice \(version, privacy: .public) (\(build, privacy: .public)) from \(Bundle.main.bundlePath, privacy: .public): \
    accessibility=\(Permissions.accessibility ? "granted" : "missing", privacy: .public), \
    microphone=\(microphone, privacy: .public), \
    keys=\(keys.isEmpty ? "none" : keys, privacy: .public) read in \(keychainMs, format: .fixed(precision: 1), privacy: .public) ms
    """)
  }

  private var needsSetup: Bool {
    !settings.onboardingCompleted || !EngineFactory.activeMissingKeys(settings).isEmpty || EngineFactory.missingServer(settings) || !Permissions.accessibility
      || Permissions.microphone != .authorized
  }

  /// The event tap requires Accessibility: retried until it is granted.
  private func startHotkeysWhenTrusted() {
    if Permissions.accessibility, hotkeys.start() { return }
    accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      if Permissions.accessibility, self.hotkeys.start() {
        timer.invalidate()
        self.accessibilityTimer = nil
      }
    }
  }

  private func statusLine() -> String {
    if !Permissions.accessibility { return String(localized: "Accessibility permission missing") }
    if Permissions.microphone != .authorized { return String(localized: "Microphone permission missing") }
    if let provider = EngineFactory.activeMissingKeys(settings).first {
      return String(localized: "\(provider.displayName) API key missing")
    }
    if EngineFactory.missingServer(settings) { return String(localized: "OpenAI-compatible server address missing") }
    if !hotkeys.isRunning { return String(localized: "Shortcuts not active") }
    return settings.fnEnabled ? String(localized: "Ready: hold Fn") : String(localized: "Ready")
  }

  private func model() -> SetupModel {
    if let setupModel { return setupModel }
    let model = SetupModel(settings: settings)
    setupModel = model
    return model
  }

  private func showSetup() {
    let model = model()
    model.refresh()
    windows.show("setup", title: "diVoice") {
      OnboardingView(
        model: model, settings: settings, onInvite: { [weak self] link in self?.showJoin(link) },
        onCreate: { [weak self] in self?.showCreateOrganization() }
      ) { [weak self] in
        self?.settings.onboardingCompleted = true
        self?.windows.close("setup")
      }
    }
  }

  private func showSettings(page: SettingsView.Page? = nil) {
    let model = model()
    model.refresh()
    windows.show("settings", title: String(localized: "diVoice Settings")) {
      SettingsView(settings: settings, setup: model, history: history, page: page ?? .general)
    }
    // The window may already be open on another page.
    if let page { NotificationCenter.default.post(name: .diVoiceShowSettingsPage, object: page) }
  }
}
