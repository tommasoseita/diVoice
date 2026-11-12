import Foundation

/// Conversions for the audio sent to the backend: PCM s16le, 16 kHz, mono.
public enum PCM {
  public static let sampleRate = 16_000
  /// 100 ms of audio.
  public static let frameBytes = sampleRate / 10 * 2

  /// Float [-1, 1] → Int16 little-endian, with clipping.
  public static func int16LittleEndian(_ samples: UnsafeBufferPointer<Float>) -> Data {
    var data = Data(count: samples.count * 2)
    data.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: Int16.self)
      for (i, sample) in samples.enumerated() {
        let clamped = max(-1, min(1, sample))
        out[i] = Int16(clamped * Float(Int16.max)).littleEndian
      }
    }
    return data
  }

  /// Level for the waveform: RMS in dB mapped to 0...1 (-50 dB to 0 dB).
  public static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for s in samples { sum += s * s }
    let rms = (sum / Float(samples.count)).squareRoot()
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return max(0, min(1, (db + 50) / 50))
  }

  public static func durationMs(bytes: Int, sampleRate: Int = sampleRate) -> Int {
    bytes * 1000 / (sampleRate * 2)
  }

  /// 100 ms of mono 16-bit audio at `sampleRate`.
  public static func frameBytes(sampleRate: Int) -> Int {
    sampleRate / 10 * 2
  }
}

/// Groups the audio into fixed-size chunks.
public struct PCMFramer: Sendable {
  public let frameBytes: Int
  private var buffer = Data()

  public init(frameBytes: Int = PCM.frameBytes) {
    self.frameBytes = frameBytes
  }

  public mutating func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var frames: [Data] = []
    while buffer.count >= frameBytes {
      frames.append(Data(buffer.prefix(frameBytes)))
      buffer.removeFirst(frameBytes)
    }
    return frames
  }

  /// What is left, if any.
  public mutating func flush() -> Data? {
    defer { buffer = Data() }
    return buffer.isEmpty ? nil : buffer
  }
}

/// The last stretch of audio, for the moment before a dictation starts: older audio drops out.
public struct PCMRing: Sendable {
  /// In bytes, whole 16-bit samples.
  public let capacity: Int
  private var buffer = Data()

  public init(capacity: Int) {
    self.capacity = max(0, capacity - capacity % 2)
  }

  /// `ms` of mono 16-bit audio at `sampleRate`.
  public init(ms: Int, sampleRate: Int) {
    self.init(capacity: sampleRate * ms / 1000 * 2)
  }

  public var count: Int { buffer.count }

  public mutating func append(_ data: Data) {
    buffer.append(data)
    if buffer.count > capacity { buffer = Data(buffer.suffix(capacity)) }
  }

  /// Everything held, oldest first; the ring is empty afterwards.
  public mutating func take() -> Data {
    defer { buffer = Data() }
    return buffer
  }

  public mutating func reset() {
    buffer = Data()
  }
}
