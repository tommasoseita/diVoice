/// Mode of a voice session.
public enum DictationMode: String, Codable, Sendable {
  case dictation
  case scribe
}

/// CGEventFlags bits used here, without depending on CoreGraphics.
public enum EventFlag {
  public static let control: UInt64 = 0x0004_0000
  public static let secondaryFn: UInt64 = 0x0080_0000
  /// "Device dependent" bits that tell the right key from the left one.
  public static let rightCommand: UInt64 = 0x0000_0010
  public static let rightOption: UInt64 = 0x0000_0040
}

public enum KeyCode {
  public static let function: UInt16 = 63
  public static let rightCommand: UInt16 = 54
  public static let rightOption: UInt16 = 61
  public static let escape: UInt16 = 53
  /// What macOS sends (key down and up) right after a quick tap of 🌐/Fn is released.
  public static let globeTap: UInt16 = 179
  public static let returnKey: UInt16 = 36
  public static let keypadEnter: UInt16 = 76
}

/// A modifier key that starts dictation while held down.
public struct HotkeyTrigger: Equatable, Hashable, Sendable {
  public let id: String
  public let keyCode: UInt16
  /// Flag bit present while the key is pressed.
  public let pressedMask: UInt64

  public init(id: String, keyCode: UInt16, pressedMask: UInt64) {
    self.id = id
    self.keyCode = keyCode
    self.pressedMask = pressedMask
  }

  public static let fn = HotkeyTrigger(id: "fn", keyCode: KeyCode.function, pressedMask: EventFlag.secondaryFn)
  public static let rightCommand = HotkeyTrigger(id: "rightCommand", keyCode: KeyCode.rightCommand, pressedMask: EventFlag.rightCommand)
  public static let rightOption = HotkeyTrigger(id: "rightOption", keyCode: KeyCode.rightOption, pressedMask: EventFlag.rightOption)

  public static let all: [HotkeyTrigger] = [.fn, .rightCommand, .rightOption]

  public static func byID(_ id: String) -> HotkeyTrigger? {
    all.first { $0.id == id }
  }
}

public enum KeyEvent: Equatable, Sendable {
  /// A modifier changed. `timestamp` in uptime nanoseconds.
  case flagsChanged(keyCode: UInt16, flags: UInt64, timestamp: UInt64)
  case keyDown(keyCode: UInt16, flags: UInt64, timestamp: UInt64)
}

public enum CancelReason: Equatable, Sendable {
  /// Press shorter than the threshold: a tap, not a dictation.
  case tooShort
  /// Another key pressed together: it was a shortcut (Fn+arrow, ⌘+C...).
  case otherKey
  case escape
}

public enum HotkeyAction: Equatable, Sendable {
  case start(DictationMode, timestamp: UInt64)
  case modeChanged(DictationMode)
  /// A double tap: the session goes on hands-free until the same key (`key`, a trigger id) is pressed again.
  case lock(DictationMode, key: String)
  case stop(DictationMode, timestamp: UInt64, heldNs: UInt64)
  case cancel(CancelReason)
}

/// Push-to-talk state machine, with a hands-free mode.
///
/// - Fn (or the alternate key) pressed: recording starts.
/// - Ctrl pressed before or during the press: the session becomes Scribe.
/// - Release after `tapMaxNs` or more: stop.
/// - A quicker release may be the first of a double tap: the recording goes on for `doubleTapNs`.
///   Pressed again in that time, the session locks: it goes on hands-free, and the next press of
///   the key stops it. Otherwise `tick` ends it: stop if it lasted `minHoldNs`, cancelled as a tap
///   if not.
/// - A non-modifier key during the press: cancelled (it was a shortcut). Hands-free, other keys
///   pass and only Esc cancels.
public struct HotkeyStateMachine: Sendable {
  public var triggers: [HotkeyTrigger]
  public var minHoldNs: UInt64
  /// Releases quicker than this may be the first tap of a double tap.
  public var tapMaxNs: UInt64
  /// Time between the first release and the second press of a double tap.
  public var doubleTapNs: UInt64

  private enum State: Sendable {
    case idle
    case holding(trigger: HotkeyTrigger, start: UInt64, mode: DictationMode)
    /// Released quickly: a second press soon locks the session, otherwise `tick` ends it.
    case awaitingSecondTap(trigger: HotkeyTrigger, start: UInt64, mode: DictationMode, released: UInt64)
    /// Locked by the second press, which is still down.
    case lockedPressed(trigger: HotkeyTrigger, start: UInt64, mode: DictationMode)
    /// Hands-free: the next press of the key stops.
    case locked(trigger: HotkeyTrigger, start: UInt64, mode: DictationMode)
    /// Ended or cancelled: only the key release is awaited.
    case suppressed(trigger: HotkeyTrigger)
  }

  private var state: State = .idle

  public init(triggers: [HotkeyTrigger], minHoldNs: UInt64 = 150_000_000, tapMaxNs: UInt64 = 300_000_000, doubleTapNs: UInt64 = 400_000_000) {
    self.triggers = triggers
    self.minHoldNs = minHoldNs
    self.tapMaxNs = tapMaxNs
    self.doubleTapNs = doubleTapNs
  }

  /// A session is recording (held, hands-free, or waiting for a second tap).
  public var isHolding: Bool {
    switch state {
    case .holding, .awaitingSecondTap, .lockedPressed, .locked: true
    case .idle, .suppressed: false
    }
  }

  public var isLocked: Bool {
    switch state {
    case .locked, .lockedPressed: true
    default: false
    }
  }

  /// When `tick` should run: the end of the double tap window, if one is open.
  public var deadline: UInt64? {
    if case let .awaitingSecondTap(_, _, _, released) = state { return released + doubleTapNs }
    return nil
  }

  public mutating func reset() {
    state = .idle
  }

  /// Ends a double tap window that has passed.
  public mutating func tick(now: UInt64) -> [HotkeyAction] {
    guard let deadline, now >= deadline else { return [] }
    return endWithoutSecondTap()
  }

  private mutating func endWithoutSecondTap() -> [HotkeyAction] {
    guard case let .awaitingSecondTap(_, start, mode, released) = state else { return [] }
    state = .idle
    let held = released > start ? released - start : 0
    return held < minHoldNs ? [.cancel(.tooShort)] : [.stop(mode, timestamp: released, heldNs: held)]
  }

  public mutating func handle(_ event: KeyEvent) -> [HotkeyAction] {
    switch event {
    case let .flagsChanged(keyCode, flags, timestamp):
      return flagsChanged(keyCode: keyCode, flags: flags, timestamp: timestamp)
    case let .keyDown(keyCode, _, timestamp):
      // Not typing: macOS reporting the tap of 🌐/Fn that was just released.
      if keyCode == KeyCode.globeTap { return [] }
      switch state {
      case let .holding(trigger, _, _), let .lockedPressed(trigger, _, _):
        state = .suppressed(trigger: trigger)
        return [.cancel(keyCode == KeyCode.escape ? .escape : .otherKey)]
      case .locked:
        // Hands-free the user may type: only Esc cancels.
        guard keyCode == KeyCode.escape else { return [] }
        state = .idle
        return [.cancel(.escape)]
      case .awaitingSecondTap:
        if keyCode == KeyCode.escape {
          state = .idle
          return [.cancel(.escape)]
        }
        // Typing right after a tap: it wasn't a double tap.
        return tick(now: max(timestamp, deadline ?? timestamp))
      case .idle, .suppressed:
        return []
      }
    }
  }

  private mutating func flagsChanged(keyCode: UInt16, flags: UInt64, timestamp: UInt64) -> [HotkeyAction] {
    let controlDown = flags & EventFlag.control != 0

    if let trigger = triggers.first(where: { $0.keyCode == keyCode }) {
      let pressed = flags & trigger.pressedMask != 0
      switch state {
      case .idle where pressed:
        let mode: DictationMode = controlDown ? .scribe : .dictation
        state = .holding(trigger: trigger, start: timestamp, mode: mode)
        return [.start(mode, timestamp: timestamp)]
      case let .holding(current, start, mode) where current == trigger && !pressed:
        let held = timestamp > start ? timestamp - start : 0
        if held < tapMaxNs {
          state = .awaitingSecondTap(trigger: trigger, start: start, mode: mode, released: timestamp)
          return []
        }
        state = .idle
        return [.stop(mode, timestamp: timestamp, heldNs: held)]
      case let .awaitingSecondTap(current, start, mode, released) where current == trigger && pressed:
        guard timestamp <= released + doubleTapNs else {
          // Too late for a double tap: the first one ends, and this press starts anew.
          let ended = endWithoutSecondTap()
          return ended + flagsChanged(keyCode: keyCode, flags: flags, timestamp: timestamp)
        }
        let locked: DictationMode = controlDown ? .scribe : mode
        state = .lockedPressed(trigger: trigger, start: start, mode: locked)
        return locked == mode ? [.lock(locked, key: trigger.id)] : [.modeChanged(locked), .lock(locked, key: trigger.id)]
      case let .lockedPressed(current, start, mode) where current == trigger && !pressed:
        state = .locked(trigger: trigger, start: start, mode: mode)
        return []
      case let .locked(current, start, mode) where current == trigger && pressed:
        state = .suppressed(trigger: trigger)
        let held = timestamp > start ? timestamp - start : 0
        return [.stop(mode, timestamp: timestamp, heldNs: held)]
      case let .suppressed(current) where current == trigger && !pressed:
        state = .idle
        return []
      default:
        break
      }
    }

    // Ctrl added during the press: switch to Scribe (no going back). Hands-free, the mode stays.
    if case let .holding(trigger, start, mode) = state, mode == .dictation, controlDown {
      state = .holding(trigger: trigger, start: start, mode: .scribe)
      return [.modeChanged(.scribe)]
    }
    return []
  }
}
