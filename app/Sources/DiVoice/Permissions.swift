import AppKit
import ApplicationServices
import AVFoundation

extension Notification.Name {
  static let diVoiceMicrophoneAllowed = Notification.Name("diVoiceMicrophoneAllowed")
}

enum Permissions {
  static var microphone: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      DispatchQueue.main.async {
        // The microphone can be got ready now.
        if granted { NotificationCenter.default.post(name: .diVoiceMicrophoneAllowed, object: nil) }
        completion(granted)
      }
    }
  }

  /// Needed for the event tap (Fn) and for reading the focused field.
  static var accessibility: Bool {
    AXIsProcessTrusted()
  }

  static func promptAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func openAccessibilitySettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  static func openMicrophoneSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
  }

  static func openKeyboardSettings() {
    open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
  }

  private static func open(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
  }

  /// What macOS does when the 🌐/Fn key is pressed. For diVoice it must be "Do Nothing".
  enum GlobeKeyAction: Equatable {
    case doNothing
    case changeInputSource
    case emoji
    case dictation
    case systemDefault

    var label: String {
      switch self {
      case .doNothing: return String(localized: "Do Nothing")
      case .changeInputSource: return String(localized: "Change Input Source")
      case .emoji: return String(localized: "Show Emoji & Symbols")
      case .dictation: return String(localized: "Start Dictation")
      case .systemDefault: return String(localized: "macOS default")
      }
    }

    var isCompatible: Bool { self == .doNothing }
  }

  static var globeKey: GlobeKeyAction {
    let domain = "com.apple.HIToolbox" as CFString
    CFPreferencesAppSynchronize(domain)
    guard let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int else { return .systemDefault }
    switch value {
    case 0: return .doNothing
    case 1: return .changeInputSource
    case 2: return .emoji
    case 3: return .dictation
    default: return .systemDefault
    }
  }
}
