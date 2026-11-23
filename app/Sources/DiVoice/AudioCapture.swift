import AVFoundation
import CoreAudio
import DiVoiceCore
import DiVoiceObjC

struct AudioInputDevice: Identifiable, Hashable {
  let id: AudioDeviceID
  let uid: String
  let name: String
}

/// Lists the microphones through Core Audio.
enum AudioDevices {
  static func inputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      guard inputChannels(id) > 0,
            let uid = string(id, kAudioDevicePropertyDeviceUID),
            let name = string(id, kAudioObjectPropertyName)
      else { return nil }
      return AudioInputDevice(id: id, uid: uid, name: name)
    }
  }

  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    inputDevices().first { $0.uid == uid }?.id
  }

  /// The chosen microphone, or the system's when none is chosen, is a Bluetooth headset.
  static func isBluetooth(uid: String) -> Bool {
    guard let id = uid.isEmpty ? defaultInputDevice() : deviceID(forUID: uid) else { return false }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
  }

  private static func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
  }

  private static func inputChannels(_ id: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
}

/// Captures from the microphone and converts to mono PCM s16le at the provider's sample rate
/// (16 kHz Mistral, 24 kHz OpenAI), in 100 ms chunks.
///
/// Ready (`standby`): between dictations the microphone stays on and only the last
/// `preRollMs` are kept, in memory; a dictation starts with them, so the words said while
/// the key goes down aren't cut. Otherwise the microphone turns on at the key press, which
/// takes about 0.2 s.
///
/// Everything that touches the audio hardware runs on `control`, in order, never on the main
/// thread: a microphone that doesn't answer (a headset connecting, a stuck audio driver) can
/// hold up a dictation, not the app. The commands return at once; `start` and `stop` report
/// back on the main thread.
///
/// A Bluetooth headset switches to its call profile (16 kHz, music spoiled) whenever its
/// microphone is opened, even just prepared, and each switch is a device change: its microphone
/// is set up only at the key press and let go as soon as the dictation ends.
final class AudioCapture {
  enum CaptureError: LocalizedError {
    case noInput
    case converter
    /// The microphone changed while it was being set up (a headset connecting).
    case changed

    var errorDescription: String? {
      switch self {
      case .noInput: return String(localized: "no microphone available")
      case .converter: return String(localized: "unsupported audio format")
      case .changed: return String(localized: "the microphone changed while starting, try again")
      }
    }
  }

  /// Where a dictation's audio goes. `frame` and `level` are called on the audio queue.
  struct Handlers {
    var frame: (Data) -> Void
    var level: (Float) -> Void
    /// When the audio starts: the first buffer after the microphone turns on, or at once when
    /// ready. On the engine's thread or `control`.
    var firstBuffer: (UInt64) -> Void
  }

  /// What a dictation gets from before the key press.
  static let preRollMs = 500
  /// After a device change a ready microphone comes back on this much later, once the new
  /// device has settled (a Bluetooth headset takes a moment to switch profile).
  static let settleSeconds = 1.0
  /// Tries at a key press while the microphone keeps changing (a Bluetooth headset takes about a
  /// second to switch profile), `retryDelay` apart.
  static let startAttempts = 5
  static let retryDelay = 0.4
  /// A replaced engine is released this much later: AVAudioEngine's own queue can still call
  /// into it for a moment after a device change, and crashes if it's gone.
  static let retiredSeconds = 10.0

  /// The audio hardware: engine, device, start and stop.
  private let control = DispatchQueue(label: "app.wibo.divoice.audio.control", qos: .userInitiated)
  /// The converted audio: the frames of a dictation, or the ring between dictations.
  private let queue = DispatchQueue(label: "app.wibo.divoice.audio", qos: .userInteractive)

  // On `control`.
  private var engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var framer = PCMFramer()
  private var outputFormat = AudioCapture.format(PCM.sampleRate)
  private(set) var sampleRate = PCM.sampleRate
  private var engineNeedsRebuild = false
  private var configuredDeviceUID: String?
  private var observer: NSObjectProtocol?
  private var prepared = false
  private var firstBufferPending = false
  /// A dictation is being captured.
  private var isRunning = false
  /// The engine is on: for a dictation, or ready between dictations.
  private var engineRunning = false
  /// Ready between dictations was asked for, with this microphone and sample rate.
  private var keepReady = false
  private var readyDeviceUID = ""
  private var readySampleRate = PCM.sampleRate
  /// The ready microphone is a Bluetooth headset: it isn't kept on.
  private var bluetooth = false
  /// Device changes so far: a burst of them brings a ready microphone back on once, after the last.
  private var changes = 0
  /// Replaced engines, kept for `retiredSeconds`.
  private var retired: [AVAudioEngine] = []
  /// The current dictation's, set on `control` before the engine starts.
  private var firstBuffer: ((UInt64) -> Void)?

  // On `queue`.
  /// Frames go to `handlers` while recording, otherwise into the ring.
  private var recording = false
  private var handlers: Handlers?
  private var preRoll = PCMRing(ms: AudioCapture.preRollMs, sampleRate: PCM.sampleRate)

  /// Setting the device can itself report a configuration change: not one to act on. Read on
  /// the thread that posts the change, hence the lock.
  private let configuringLock = NSLock()
  private var configuringNow = false
  private var configuring: Bool {
    get { configuringLock.withLock { configuringNow } }
    set { configuringLock.withLock { configuringNow = newValue } }
  }

  init() {
    observeConfigurationChanges()
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  // MARK: Commands, from the main thread

  /// Prepares engine, device and converter ahead of time, so that on key press only the
  /// hardware start remains. Does not turn the microphone on.
  func prepare(deviceUID: String, sampleRate: Int) {
    control.async {
      if AudioDevices.isBluetooth(uid: deviceUID) {
        self.releaseMicrophone()
      } else {
        self.prepareNow(deviceUID: deviceUID, sampleRate: sampleRate)
      }
    }
  }

  /// Keeps the microphone on between dictations with the last `preRollMs` in memory. Not with a
  /// Bluetooth headset: an open microphone switches it to its call profile, which spoils what it
  /// plays. During a dictation the request waits for its end.
  func standby(deviceUID: String, sampleRate: Int) {
    control.async {
      self.keepReady = true
      self.readyDeviceUID = deviceUID
      self.readySampleRate = sampleRate
      guard !self.isRunning else { return }
      self.resumeStandby()
    }
  }

  /// The microphone off between dictations until `standby` again (the Mac sleeps or locks).
  func pauseStandby() {
    control.async {
      guard !self.isRunning else { return }
      self.stopEngine()
    }
  }

  /// The microphone turns on only at the key press again.
  func endStandby() {
    control.async {
      self.keepReady = false
      guard !self.isRunning else { return }
      self.stopEngine()
    }
  }

  /// Turns the microphone on for a dictation. `completion` runs on the main thread, with the
  /// error if it couldn't start; it doesn't run while the microphone doesn't answer.
  func start(deviceUID: String, sampleRate: Int, handlers: Handlers, completion: @escaping (Error?) -> Void) {
    control.async {
      var failure: Error?
      do {
        try self.startNow(deviceUID: deviceUID, sampleRate: sampleRate, handlers: handlers)
      } catch {
        failure = error
      }
      DispatchQueue.main.async { completion(failure) }
    }
  }

  /// Stops capturing; `completion` gets the remaining audio (less than 100 ms) on the main thread.
  func stop(completion: ((Data?) -> Void)? = nil) {
    control.async {
      let rest = self.stopNow()
      if let completion { DispatchQueue.main.async { completion(rest) } }
    }
  }

  // MARK: Device changes

  private func observeConfigurationChanges() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    let observed = engine
    // Device or format change: the engine stops and is recreated at the next recording; when
    // ready, it comes back on once the device has settled (or stays off for a Bluetooth headset).
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: observed, queue: nil
    ) { [weak self] _ in
      guard let self, !self.configuring else { return }
      self.control.async { self.configurationChanged(observed) }
    }
  }

  private func configurationChanged(_ observed: AVAudioEngine) {
    guard observed === engine else { return }
    // A real change stops the engine; one that left it running needs nothing.
    if engineRunning, engine.isRunning { return }
    engineNeedsRebuild = true
    appLog.notice("Microphone changed")
    changes += 1
    let change = changes
    guard keepReady, !isRunning else { return }
    control.asyncAfter(deadline: .now() + Self.settleSeconds) { [weak self] in
      guard let self, change == self.changes, self.keepReady, !self.isRunning, !self.engine.isRunning else { return }
      self.resumeStandby()
    }
  }

  /// Keeps a replaced engine, stopped, for `retiredSeconds` before releasing it.
  private func retire(_ old: AVAudioEngine) {
    old.stop()
    retired.append(old)
    control.asyncAfter(deadline: .now() + Self.retiredSeconds) { [weak self] in
      guard let self, !self.retired.isEmpty else { return }
      self.retired.removeFirst()
    }
  }

  /// Lets go of the microphone, so that a Bluetooth headset goes back to its music profile. The
  /// next dictation sets it up again.
  private func releaseMicrophone() {
    guard !isRunning, configuredDeviceUID != nil else { return }
    stopEngine(prepareAgain: false)
    if prepared { try? guarded("tap removal") { engine.inputNode.removeTap(onBus: 0) } }
    prepared = false
    retire(engine)
    engine = AVAudioEngine()
    observeConfigurationChanges()
    engineNeedsRebuild = false
    configuredDeviceUID = nil
  }

  /// AVAudioEngine reports some failures with an Objective-C exception instead of an error, such
  /// as a microphone that changes format while it's being set up: without this they would quit
  /// diVoice.
  private func guarded(_ step: String, _ body: () throws -> Void) throws {
    var failure: Error?
    let exception = DVCatchException {
      do {
        try body()
      } catch {
        failure = error
      }
    }
    if let exception {
      appLog.error("Microphone \(step, privacy: .public): \(exception.name.rawValue, privacy: .public) \(exception.reason ?? "", privacy: .public)")
      throw CaptureError.changed
    }
    if let failure { throw failure }
  }

  // MARK: On `control`

  private func prepareNow(deviceUID: String, sampleRate: Int) {
    guard !isRunning, !engineRunning else { return }
    if prepared && !engineNeedsRebuild && configuredDeviceUID == deviceUID && self.sampleRate == sampleRate { return }
    configuring = true
    defer { configuring = false }
    self.sampleRate = sampleRate
    outputFormat = Self.format(sampleRate)
    if prepared { try? guarded("tap removal") { engine.inputNode.removeTap(onBus: 0) } }
    prepared = false
    retire(engine)
    engine = AVAudioEngine()
    observeConfigurationChanges()
    engineNeedsRebuild = false
    configuredDeviceUID = deviceUID

    do {
      try guarded("setup") {
        let input = engine.inputNode
        if !deviceUID.isEmpty, let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
          var device = id
          AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
          )
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
          self?.process(buffer)
        }
        engine.prepare()
        prepared = true
      }
    } catch {
      // The device changed meanwhile: a new engine next time.
      prepared = false
      engineNeedsRebuild = true
    }
  }

  private var isReady: Bool {
    !bluetooth && engineRunning && engine.isRunning && !engineNeedsRebuild && configuredDeviceUID == readyDeviceUID && sampleRate == readySampleRate
  }

  /// `retry`: a device still settling gets one more try a moment later.
  private func resumeStandby(retry: Bool = true) {
    guard keepReady, !isRunning else { return }
    let change = changes
    let tryAgain = { [weak self] in
      guard retry, let self else { return }
      self.control.asyncAfter(deadline: .now() + Self.settleSeconds) { [weak self] in
        guard let self, change == self.changes else { return }
        self.resumeStandby(retry: false)
      }
    }
    bluetooth = AudioDevices.isBluetooth(uid: readyDeviceUID)
    if bluetooth {
      releaseMicrophone()
      return
    }
    if isReady { return }
    stopEngine()
    prepareNow(deviceUID: readyDeviceUID, sampleRate: readySampleRate)
    guard prepared, let converter else {
      tryAgain()
      return
    }
    converter.reset()
    let sampleRate = self.sampleRate
    queue.sync {
      recording = false
      preRoll = PCMRing(ms: Self.preRollMs, sampleRate: sampleRate)
    }
    firstBufferPending = false
    do {
      try guarded("start") { try engine.start() }
      engineRunning = true
    } catch {
      engineNeedsRebuild = true
      appLog.error("Microphone not ready: \(error.localizedDescription, privacy: .public)")
      tryAgain()
    }
  }

  /// `prepareAgain`: ready for a quick start at the next key press.
  private func stopEngine(prepareAgain: Bool = true) {
    guard engineRunning else { return }
    engine.stop()
    engineRunning = false
    queue.sync { preRoll.reset() }
    guard prepareAgain, !engineNeedsRebuild else { return }
    do {
      try guarded("prepare") { engine.prepare() }
    } catch {
      engineNeedsRebuild = true
    }
  }

  private func startNow(deviceUID: String, sampleRate: Int, handlers: Handlers) throws {
    if isRunning { _ = stopNow() }
    let frameBytes = PCM.frameBytes(sampleRate: sampleRate)
    // Ready: the moment before the key goes first, in order, then the live audio.
    if keepReady, isReady, deviceUID == readyDeviceUID, sampleRate == readySampleRate {
      queue.sync {
        self.handlers = handlers
        framer = PCMFramer(frameBytes: frameBytes)
        recording = true
        for frame in framer.append(preRoll.take()) { handlers.frame(frame) }
      }
      isRunning = true
      handlers.firstBuffer(MonotonicClock.nowNs())
      return
    }
    // While a Bluetooth headset switches to its call profile, its format changes under the
    // engine: a few more tries before giving up.
    var attempt = 1
    while true {
      do {
        try openMicrophone(deviceUID: deviceUID, sampleRate: sampleRate, frameBytes: frameBytes, handlers: handlers)
        return
      } catch CaptureError.changed where attempt < Self.startAttempts {
        attempt += 1
        Thread.sleep(forTimeInterval: Self.retryDelay)
      }
    }
  }

  private func openMicrophone(deviceUID: String, sampleRate: Int, frameBytes: Int, handlers: Handlers) throws {
    stopEngine()
    prepareNow(deviceUID: deviceUID, sampleRate: sampleRate)
    guard prepared, let converter else { throw engineNeedsRebuild ? CaptureError.changed : CaptureError.noInput }
    converter.reset()
    queue.sync {
      self.handlers = handlers
      framer = PCMFramer(frameBytes: frameBytes)
      recording = true
    }
    firstBuffer = handlers.firstBuffer
    firstBufferPending = true
    do {
      try guarded("start") { try engine.start() }
    } catch {
      engineNeedsRebuild = true
      queue.sync { recording = false }
      throw error
    }
    engineRunning = true
    isRunning = true
  }

  private static func format(_ sampleRate: Int) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
  }

  /// Stops capturing and returns the remaining audio (less than 100 ms).
  private func stopNow() -> Data? {
    guard isRunning else { return nil }
    isRunning = false
    // Ready: the microphone stays on and the ring starts over.
    if keepReady, isReady {
      return queue.sync {
        recording = false
        preRoll.reset()
        return framer.flush()
      }
    }
    stopEngine(prepareAgain: false)
    // After the chunks already queued, the rest.
    let rest = queue.sync {
      recording = false
      return framer.flush()
    }
    if AudioDevices.isBluetooth(uid: configuredDeviceUID ?? "") {
      releaseMicrophone()
    } else if keepReady {
      // On again if asked meanwhile (another microphone, the setting turned on).
      resumeStandby()
    } else if !engineNeedsRebuild {
      do {
        try guarded("prepare") { engine.prepare() }
      } catch {
        engineNeedsRebuild = true
      }
    }
    return rest
  }

  /// On the engine's thread.
  private func process(_ buffer: AVAudioPCMBuffer) {
    if firstBufferPending {
      firstBufferPending = false
      firstBuffer?(MonotonicClock.nowNs())
    }
    var level: Float?
    if let channels = buffer.floatChannelData {
      level = PCM.level(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }
    guard let converter else { return }
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        // noDataNow (not endOfStream) keeps the resampler state between buffers.
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return }
    let data = Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    queue.async { [weak self] in
      guard let self else { return }
      // Between dictations the audio only goes into the ring, overwritten as it fills.
      guard self.recording else {
        self.preRoll.append(data)
        return
      }
      if let level { self.handlers?.level(level) }
      for frame in self.framer.append(data) { self.handlers?.frame(frame) }
    }
  }
}
