import AVFoundation
import CoreAudio
import DiVoiceCore

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
final class AudioCapture {
  enum CaptureError: LocalizedError {
    case noInput
    case converter

    var errorDescription: String? {
      switch self {
      case .noInput: return String(localized: "no microphone available")
      case .converter: return String(localized: "unsupported audio format")
      }
    }
  }

  /// Called on the audio queue.
  var onFrame: ((Data) -> Void)?
  var onLevel: ((Float) -> Void)?
  /// When the audio starts: the first buffer after the microphone turns on, or at once when ready.
  var onFirstBuffer: ((UInt64) -> Void)?

  /// What a dictation gets from before the key press.
  static let preRollMs = 500

  private var engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var framer = PCMFramer()
  private let queue = DispatchQueue(label: "app.wibo.divoice.audio", qos: .userInteractive)
  private var outputFormat = AudioCapture.format(PCM.sampleRate)
  private(set) var sampleRate = PCM.sampleRate
  private var engineNeedsRebuild = false
  private var configuredDeviceUID: String?
  private var observer: NSObjectProtocol?
  private var prepared = false
  /// Setting the device can itself report a configuration change: not one to act on.
  private var configuring = false
  private var firstBufferPending = false
  /// A dictation is being captured.
  private(set) var isRunning = false
  /// The engine is on: for a dictation, or ready between dictations.
  private var engineRunning = false
  /// Ready between dictations was asked for, with this microphone and sample rate.
  private var keepReady = false
  private var readyDeviceUID = ""
  private var readySampleRate = PCM.sampleRate
  /// The ready microphone is a Bluetooth headset: it isn't kept on.
  private var bluetooth = false
  /// On `queue`: frames go to `onFrame` while recording, otherwise into the ring.
  private var recording = false
  private var preRoll = PCMRing(ms: AudioCapture.preRollMs, sampleRate: PCM.sampleRate)

  init() {
    observeConfigurationChanges()
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func observeConfigurationChanges() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    // Device or format change: the engine stops and is recreated at the next recording; when
    // ready, it comes back on (or stays off for a Bluetooth headset).
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      guard let self, !self.configuring else { return }
      // A real change stops the engine; one that left it running needs nothing.
      if self.engineRunning, self.engine.isRunning { return }
      self.engineNeedsRebuild = true
      guard self.keepReady, !self.isRunning else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self, self.keepReady, !self.isRunning, !self.engine.isRunning else { return }
        self.resumeStandby()
      }
    }
  }

  /// Prepares engine, device and converter ahead of time, so that on key press only the
  /// hardware start remains. Does not turn the microphone on.
  func prepare(deviceUID: String, sampleRate: Int) {
    guard !isRunning, !engineRunning else { return }
    if prepared && !engineNeedsRebuild && configuredDeviceUID == deviceUID && self.sampleRate == sampleRate { return }
    configuring = true
    defer { configuring = false }
    self.sampleRate = sampleRate
    outputFormat = Self.format(sampleRate)
    if prepared { engine.inputNode.removeTap(onBus: 0) }
    prepared = false
    engine = AVAudioEngine()
    observeConfigurationChanges()
    engineNeedsRebuild = false

    let input = engine.inputNode
    if !deviceUID.isEmpty, let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
      var device = id
      AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &device, UInt32(MemoryLayout<AudioDeviceID>.size)
      )
    }
    configuredDeviceUID = deviceUID

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

  // MARK: Ready between dictations

  /// Keeps the microphone on between dictations with the last `preRollMs` in memory. Not with a
  /// Bluetooth headset: an open microphone switches it to its call profile, which spoils what it
  /// plays. During a dictation the request waits for its end.
  func standby(deviceUID: String, sampleRate: Int) {
    keepReady = true
    readyDeviceUID = deviceUID
    readySampleRate = sampleRate
    guard !isRunning else { return }
    resumeStandby()
  }

  /// The microphone off between dictations until `standby` again (the Mac sleeps or locks).
  func pauseStandby() {
    guard !isRunning else { return }
    stopEngine()
  }

  /// The microphone turns on only at the key press again.
  func endStandby() {
    keepReady = false
    pauseStandby()
  }

  private var isReady: Bool {
    !bluetooth && engineRunning && engine.isRunning && !engineNeedsRebuild && configuredDeviceUID == readyDeviceUID && sampleRate == readySampleRate
  }

  private func resumeStandby() {
    guard keepReady, !isRunning else { return }
    bluetooth = AudioDevices.isBluetooth(uid: readyDeviceUID)
    if bluetooth {
      stopEngine()
      prepare(deviceUID: readyDeviceUID, sampleRate: readySampleRate)
      return
    }
    if isReady { return }
    stopEngine()
    prepare(deviceUID: readyDeviceUID, sampleRate: readySampleRate)
    guard prepared, let converter else { return }
    converter.reset()
    let sampleRate = self.sampleRate
    queue.sync {
      recording = false
      preRoll = PCMRing(ms: Self.preRollMs, sampleRate: sampleRate)
    }
    firstBufferPending = false
    do {
      try engine.start()
      engineRunning = true
    } catch {
      engineNeedsRebuild = true
    }
  }

  private func stopEngine() {
    guard engineRunning else { return }
    engine.stop()
    engineRunning = false
    queue.sync { preRoll.reset() }
    // Ready for a quick start at the next key press.
    if !engineNeedsRebuild { engine.prepare() }
  }

  // MARK: A dictation

  func start(deviceUID: String, sampleRate: Int) throws {
    if isRunning { _ = stop() }
    let frameBytes = PCM.frameBytes(sampleRate: sampleRate)
    // Ready: the moment before the key goes first, in order, then the live audio.
    if keepReady, isReady, deviceUID == readyDeviceUID, sampleRate == readySampleRate {
      queue.sync {
        framer = PCMFramer(frameBytes: frameBytes)
        recording = true
        for frame in framer.append(preRoll.take()) { onFrame?(frame) }
      }
      isRunning = true
      onFirstBuffer?(MonotonicClock.nowNs())
      return
    }
    stopEngine()
    prepare(deviceUID: deviceUID, sampleRate: sampleRate)
    guard prepared, let converter else { throw CaptureError.noInput }
    converter.reset()
    queue.sync {
      framer = PCMFramer(frameBytes: frameBytes)
      recording = true
    }
    firstBufferPending = true
    do {
      try engine.start()
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
  func stop() -> Data? {
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
    stopEngine()
    // After the chunks already queued, the rest.
    let rest = queue.sync {
      recording = false
      return framer.flush()
    }
    // On again if asked meanwhile (another microphone, the setting turned on).
    if keepReady { resumeStandby() }
    return rest
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    if firstBufferPending {
      firstBufferPending = false
      onFirstBuffer?(MonotonicClock.nowNs())
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
      if let level { self.onLevel?(level) }
      for frame in self.framer.append(data) { self.onFrame?(frame) }
    }
  }
}
