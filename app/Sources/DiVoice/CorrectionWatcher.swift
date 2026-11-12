import AppKit
import ApplicationServices
import DiVoiceEngine

/// After an insertion, keeps an eye on the field until the user moves on (another field or app,
/// two minutes, the next dictation, or the message sent with Return), then reports what they
/// corrected in the dictated text. The field is read once a second, and when Return goes down,
/// before a chat sends the message and empties the field. The reads happen off the main thread;
/// nothing is kept once the correction is reported.
final class CorrectionWatcher {
  var onCorrection: ((Correction, AppCategory) -> Void)?

  private struct Watch {
    let field: AXUIElement
    let pid: pid_t
    let inserted: String
    let category: AppCategory
    let started = Date()
    var baseline: String?
    var range: NSRange?
    /// The latest correction seen: a message sent (the field emptied) keeps the one before.
    var latest: Correction?
  }

  private let queue = DispatchQueue(label: "app.wibo.divoice.corrections")
  private var timer: DispatchSourceTimer?
  private var watch: Watch?
  private static let maxDuration: TimeInterval = 120
  /// The watched field, for `returnPressed` on the hotkey thread, which doesn't wait for `queue`.
  private let watchedLock = NSLock()
  private var watched: (field: AXUIElement, pid: pid_t)?

  /// Starts watching `field` in the app `pid`, where `inserted` was just pasted.
  func watch(field: AXUIElement, pid: pid_t, inserted: String, category: AppCategory) {
    finish()
    queue.async {
      // After the previous watch has ended (`finish` runs first on this queue).
      self.watchedLock.withLock { self.watched = (field, pid) }
      self.watch = Watch(field: field, pid: pid, inserted: inserted, category: category)
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      // The paste lands a moment later: the first read is the baseline.
      timer.schedule(deadline: .now() + 0.4, repeating: 1.0)
      timer.setEventHandler { [weak self] in self?.tick() }
      self.timer = timer
      timer.resume()
    }
  }

  /// Stops watching and reports the correction, if there was one.
  func finish() {
    queue.async { self.stop() }
  }

  /// Return or Enter is going down, on the hotkey thread, before the app gets it: in a chat the
  /// field still holds the message about to be sent. One short read, only while a dictated text
  /// is watched in the frontmost app.
  func returnPressed() {
    guard let watched = watchedLock.withLock({ watched }),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == watched.pid
    else { return }
    AXUIElementSetMessagingTimeout(watched.field, 0.1)
    let value = Self.string(watched.field, kAXValueAttribute)
    queue.async { self.sending(value) }
  }

  /// The text as it was when Return went down; if the field then empties, it was sent: the
  /// watch ends there. Otherwise Return was a new line or picked a suggestion: it goes on.
  private func sending(_ value: String?) {
    guard var current = watch, let baseline = current.baseline, let range = current.range else { return }
    if let value, let correction = CorrectionDiff.find(baseline: baseline, inserted: range, final: value) {
      current.latest = correction
      watch = current
    }
    let field = current.field
    queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self, let now = self.watch, CFEqual(now.field, field) else { return }
      AXUIElementSetMessagingTimeout(field, 0.15)
      if Self.string(field, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { self.stop() }
    }
  }

  private func tick() {
    guard var current = watch else { return }
    AXUIElementSetMessagingTimeout(current.field, 0.15)
    guard current.baseline != nil else {
      guard let value = Self.string(current.field, kAXValueAttribute), let range = Self.dictatedRange(current.field, value, current.inserted) else {
        // The field can't be read here: nothing to learn.
        cancel()
        return
      }
      current.baseline = value
      current.range = range
      watch = current
      return
    }
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let focused = Self.focusedElement(current.pid)
    guard frontmost == current.pid, let focused, CFEqual(focused, current.field), Date().timeIntervalSince(current.started) < Self.maxDuration
    else {
      stop()
      return
    }
    if let value = Self.string(current.field, kAXValueAttribute), let baseline = current.baseline, let range = current.range,
      let correction = CorrectionDiff.find(baseline: baseline, inserted: range, final: value)
    {
      current.latest = correction
    }
    watch = current
  }

  private func stop() {
    let ended = watch
    cancel()
    guard let ended, let correction = ended.latest else { return }
    let category = ended.category
    DispatchQueue.main.async { self.onCorrection?(correction, category) }
  }

  private func cancel() {
    timer?.cancel()
    timer = nil
    watch = nil
    watchedLock.withLock { watched = nil }
  }

  /// Where the dictated text is: right before the cursor, or its last occurrence in the field.
  private static func dictatedRange(_ field: AXUIElement, _ value: String, _ inserted: String) -> NSRange? {
    let text = value as NSString
    let length = (inserted as NSString).length
    guard length > 0 else { return nil }
    if let cursor = cursorLocation(field), cursor >= length, cursor <= text.length,
      text.substring(with: NSRange(location: cursor - length, length: length)) == inserted
    {
      return NSRange(location: cursor - length, length: length)
    }
    let found = text.range(of: inserted, options: .backwards)
    return found.location == NSNotFound ? nil : found
  }

  private static func cursorLocation(_ field: AXUIElement) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &value) == .success, let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range.location
  }

  private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }
}
