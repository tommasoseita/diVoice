import AppKit
import DiVoiceCore
import SwiftUI

final class OverlayModel: ObservableObject {
  enum Phase: Equatable {
    case hidden
    case recording
    case processing
    case info(String)
    case error(String)
  }

  static let bars = 24

  @Published var phase: Phase = .hidden
  @Published var mode: DictationMode = .dictation
  /// Hands-free after a double tap: the id of the key whose next press ends it.
  @Published var lockedKey: String?
  @Published var levels = [Float](repeating: 0, count: OverlayModel.bars)
}

/// Where the user put the overlay: the middle of its bottom edge, in screen coordinates.
/// Without one, the overlay sits at the bottom center of the screen with the pointer.
enum OverlayPosition {
  private static let key = "overlayAnchor"

  static var saved: NSPoint? {
    guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 2 else { return nil }
    return NSPoint(x: values[0], y: values[1])
  }

  static func save(_ anchor: NSPoint) {
    UserDefaults.standard.set([Double(anchor.x), Double(anchor.y)], forKey: key)
  }

  /// Settings › General › Reset position.
  static func reset() {
    UserDefaults.standard.removeObject(forKey: key)
    NotificationCenter.default.post(name: .diVoiceOverlayReset, object: nil)
  }

  /// The frame for an overlay of `size`, kept entirely on a screen: the one it overlaps most,
  /// or the nearest one when its screen is gone (a monitor unplugged).
  static func frame(anchor: NSPoint, size: NSSize, screens: [NSRect]) -> NSRect {
    var rect = NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
    guard !screens.isEmpty else { return rect }
    func overlap(_ screen: NSRect) -> CGFloat {
      let intersection = screen.intersection(rect)
      return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    func distance(_ screen: NSRect) -> CGFloat {
      let dx = max(screen.minX - anchor.x, 0, anchor.x - screen.maxX)
      let dy = max(screen.minY - anchor.y, 0, anchor.y - screen.maxY)
      return dx * dx + dy * dy
    }
    let screen = screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
      ?? screens.min { distance($0) < distance($1) }!
    rect.origin.x = min(max(rect.minX, screen.minX), screen.maxX - rect.width)
    rect.origin.y = min(max(rect.minY, screen.minY), screen.maxY - rect.height)
    return rect
  }
}

extension Notification.Name {
  static let diVoiceOverlayReset = Notification.Name("app.wibo.divoice.overlayReset")
}

/// Never becomes the key or main window: dragging it leaves the focus in the app being typed in.
private final class OverlayPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Drags anywhere on the overlay move it (its transparent margin lets clicks through).
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
  override var mouseDownCanMoveWindow: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating pill at the bottom of the screen: it never takes the focus, and the user can drag
/// it anywhere; its position is kept across launches and brought back on screen if needed.
final class OverlayController: NSObject, NSWindowDelegate {
  let model = OverlayModel()
  private let panel: NSPanel
  private var hideWork: DispatchWorkItem?
  /// True while diVoice itself moves the panel, so only the user's drags are saved.
  private var placing = false
  private static let size = NSSize(width: 440, height: 84)

  override init() {
    panel = OverlayPanel(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: true
    )
    super.init()
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.contentView = DraggableHostingView(rootView: OverlayView(model: model))
    panel.delegate = self
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(positionReset), name: .diVoiceOverlayReset, object: nil)
  }

  func showRecording(mode: DictationMode) {
    model.mode = mode
    model.lockedKey = nil
    model.levels = [Float](repeating: 0, count: OverlayModel.bars)
    show(.recording)
  }

  func setMode(_ mode: DictationMode) {
    model.mode = mode
  }

  func setLocked(key: String?) {
    model.lockedKey = key
  }

  func pushLevel(_ level: Float) {
    guard model.phase == .recording else { return }
    var levels = model.levels
    levels.removeFirst()
    levels.append(level)
    model.levels = levels
  }

  /// Scribe's text isn't shown here: it goes straight into the app when it's complete.
  func showProcessing(mode: DictationMode) {
    model.mode = mode
    show(.processing)
  }

  func showInfo(_ message: String, seconds: TimeInterval = 2.5) {
    show(.info(message), hideAfter: seconds)
  }

  func showError(_ message: String) {
    show(.error(message), hideAfter: 4)
  }

  func hide() {
    hideWork?.cancel()
    model.phase = .hidden
    panel.orderOut(nil)
  }

  private func show(_ phase: OverlayModel.Phase, hideAfter: TimeInterval? = nil) {
    hideWork?.cancel()
    model.phase = phase
    if !panel.isVisible { position() }
    panel.orderFrontRegardless()
    if let hideAfter {
      let work = DispatchWorkItem { [weak self] in self?.hide() }
      hideWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
    }
  }

  /// The saved place, kept on a visible screen; otherwise the bottom center of the pointer's screen.
  private func position() {
    let screens = NSScreen.screens.map(\.visibleFrame)
    let anchor: NSPoint
    if let saved = OverlayPosition.saved {
      anchor = saved
    } else {
      let mouse = NSEvent.mouseLocation
      let frame = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
      anchor = NSPoint(x: frame.midX, y: frame.minY + 16)
    }
    let frame = OverlayPosition.frame(anchor: anchor, size: Self.size, screens: screens)
    placing = true
    panel.setFrame(frame, display: true)
    placing = false
    // A screen went away: the overlay stays where it's now visible.
    if OverlayPosition.saved != nil, abs(frame.midX - anchor.x) > 1 || abs(frame.minY - anchor.y) > 1 {
      OverlayPosition.save(NSPoint(x: frame.midX, y: frame.minY))
    }
  }

  func windowDidMove(_ notification: Notification) {
    guard !placing else { return }
    OverlayPosition.save(NSPoint(x: panel.frame.midX, y: panel.frame.minY))
  }

  @objc private func screensChanged() {
    if panel.isVisible { position() }
  }

  @objc private func positionReset() {
    if panel.isVisible { position() }
  }
}

struct OverlayView: View {
  @ObservedObject var model: OverlayModel

  /// What ends a hands-free dictation: the key that started it.
  static func finishLabel(_ key: String) -> String {
    switch key {
    case HotkeyTrigger.rightCommand.id: String(localized: "Right ⌘ to finish")
    case HotkeyTrigger.rightOption.id: String(localized: "Right ⌥ to finish")
    default: String(localized: "Fn to finish")
    }
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      if model.phase != .hidden {
        HStack(spacing: 10) {
          icon
          content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.12), radius: 12, y: 4))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .padding(.bottom, 14)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .animation(.easeOut(duration: 0.15), value: model.phase)
  }

  @ViewBuilder private var icon: some View {
    switch model.phase {
    case .recording:
      RecordingDot()
    case .processing where model.mode == .scribe:
      PulsingSparkles()
    case .processing:
      ProgressView().controlSize(.small)
    case .info:
      Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
    case .error:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
    case .hidden:
      EmptyView()
    }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .recording:
      HStack(spacing: 10) {
        Waveform(levels: model.levels)
        if model.mode == .scribe { Pill("Scribe", icon: "sparkles") }
        // Hands-free: no key to hold, and the way out.
        if let key = model.lockedKey { Pill(verbatim: Self.finishLabel(key), icon: "lock.fill") }
      }
    case .processing where model.mode == .scribe:
      HStack(spacing: 8) {
        Text("Scribe is rewriting").font(.system(size: 12.5, weight: .medium))
        ThinkingDots()
      }
    case .processing:
      Text("Transcribing…").font(.system(size: 12.5)).foregroundStyle(.secondary)
    case let .info(message), let .error(message):
      Text(message).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
    case .hidden:
      EmptyView()
    }
  }
}

/// The recording state: the one orange accent, breathing.
struct RecordingDot: View {
  var body: some View {
    TimelineView(.animation) { context in
      let phase = context.date.timeIntervalSinceReferenceDate
      Circle()
        .fill(Theme.accent)
        .frame(width: 10, height: 10)
        .opacity(0.65 + 0.35 * sin(phase * 4))
        .padding(3)
        .background(Circle().fill(Theme.accent.opacity(0.18)))
    }
  }
}

/// Scribe's icon, pulsing while it writes.
struct PulsingSparkles: View {
  var body: some View {
    TimelineView(.animation) { context in
      let phase = context.date.timeIntervalSinceReferenceDate
      Image(systemName: "sparkles")
        .foregroundStyle(Theme.selected)
        .scaleEffect(1 + 0.15 * sin(phase * 4))
        .opacity(0.7 + 0.3 * sin(phase * 4))
    }
  }
}

/// Three dots that light up in sequence: Scribe is at work.
struct ThinkingDots: View {
  var body: some View {
    TimelineView(.animation) { context in
      let phase = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 4) {
        ForEach(0 ..< 3, id: \.self) { index in
          let wave = (sin(phase * 5 - Double(index) * 0.9) + 1) / 2
          Circle()
            .fill(Color.secondary)
            .frame(width: 4.5, height: 4.5)
            .opacity(0.3 + 0.7 * wave)
            .offset(y: -2 * wave)
        }
      }
    }
  }
}

struct Waveform: View {
  let levels: [Float]

  var body: some View {
    HStack(alignment: .center, spacing: 2.5) {
      ForEach(levels.indices, id: \.self) { index in
        Capsule()
          .fill(Theme.accent.opacity(0.55 + 0.45 * Double(min(levels[index] * 2, 1))))
          .frame(width: 3, height: 4 + CGFloat(levels[index]) * 20)
      }
    }
    .frame(height: 26)
    .animation(.linear(duration: 0.08), value: levels)
  }
}
