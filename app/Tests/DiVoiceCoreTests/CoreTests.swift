import Foundation
import Testing
@testable import DiVoiceCore

@Suite("PCM")
struct PCMTests {
  @Test func convertsFloatToInt16WithClipping() {
    let samples: [Float] = [0, 1, -1, 0.5, 2, -3]
    let data = samples.withUnsafeBufferPointer { PCM.int16LittleEndian($0) }
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
    #expect(values == [0, 32767, -32767, 16383, 32767, -32767])
  }

  @Test func waveformLevel() {
    let silence = [Float](repeating: 0, count: 100)
    let loud = [Float](repeating: 1, count: 100)
    #expect(silence.withUnsafeBufferPointer { PCM.level($0) } == 0)
    #expect(loud.withUnsafeBufferPointer { PCM.level($0) } == 1)
    let quiet = [Float](repeating: 0.01, count: 100) // -40 dB
    let level = quiet.withUnsafeBufferPointer { PCM.level($0) }
    #expect(abs(level - 0.2) < 0.001)
  }

  @Test func groupsIntoChunksOf100ms() {
    var framer = PCMFramer()
    #expect(PCM.frameBytes == 3200)
    #expect(framer.append(Data(count: 3000)).isEmpty)
    let frames = framer.append(Data(count: 3600))
    #expect(frames.map(\.count) == [3200, 3200])
    #expect(framer.flush()?.count == 200)
    #expect(framer.flush() == nil)
    #expect(PCM.durationMs(bytes: 32000) == 1000)
  }

  @Test func theRingKeepsOnlyTheLastHalfSecond() {
    var ring = PCMRing(ms: 500, sampleRate: 16_000)
    #expect(ring.capacity == 16_000)
    // Two seconds of numbered samples: only the newest half second stays, oldest first.
    var samples = Data()
    for i in 0..<32_000 { withUnsafeBytes(of: Int16(truncatingIfNeeded: i).littleEndian) { samples.append(contentsOf: $0) } }
    for start in stride(from: 0, to: samples.count, by: 2_048) { ring.append(samples.subdata(in: start..<min(start + 2_048, samples.count))) }
    let kept = ring.take()
    #expect(kept.count == 16_000)
    #expect(kept == samples.suffix(16_000))
    #expect(ring.count == 0)
    // An odd capacity rounds down to whole samples.
    #expect(PCMRing(capacity: 9).capacity == 8)
    ring.append(Data(count: 100))
    ring.reset()
    #expect(ring.take().isEmpty)
  }
}

@Suite("Timing")
struct TimingTests {
  @Test func timestampInNanoseconds() {
    let now: UInt64 = 10_000_000_000
    #expect(MonotonicClock.eventUptimeNs(now - 3_000_000, nowNs: now, timebaseNumer: 125, timebaseDenom: 3) == now - 3_000_000)
  }

  @Test func timestampInMachTicks() {
    // Apple Silicon: 1 tick = 125/3 ns.
    let now: UInt64 = 10_000_000_000
    let ticks: UInt64 = (now - 6_000_000) * 3 / 125
    let converted = MonotonicClock.eventUptimeNs(ticks, nowNs: now, timebaseNumer: 125, timebaseDenom: 3)
    #expect(converted > now - 6_000_100 && converted <= now - 5_999_900)
  }

  @Test func implausibleTimestampUsesNow() {
    let now: UInt64 = 10_000_000_000
    #expect(MonotonicClock.eventUptimeNs(now + 1_000_000_000, nowNs: now, timebaseNumer: 1, timebaseDenom: 1) == now)
    #expect(MonotonicClock.eventUptimeNs(1, nowNs: now, timebaseNumer: 1, timebaseDenom: 1) == now)
  }

  @Test func dictationMetrics() {
    let ms: UInt64 = 1_000_000
    var t = DictationTimeline(pressNs: 1000 * ms)
    t.firstAudioNs = 1080 * ms
    t.releaseNs = 4000 * ms
    t.endSentNs = 4002 * ms
    t.resultNs = 4800 * ms
    t.pastePostedNs = 4810 * ms
    #expect(t.totalMs == 810)
    t.insertedNs = 4850 * ms
    #expect(t.totalMs == 850)
    #expect(t.metrics == [
      "pressToFirstAudioMs": 80,
      "releaseToEndSentMs": 2,
      "releaseToResultMs": 800,
      "releaseToPasteMs": 810,
      "releaseToInsertedMs": 850,
      "resultToInsertedMs": 50,
    ])
  }

  @Test func percentiles() {
    let values: [Double] = [5, 1, 4, 2, 3, 10, 6, 7, 8, 9]
    #expect(Stats.percentile(values, 50) == 5)
    #expect(Stats.percentile(values, 95) == 10)
    #expect(Stats.percentile([], 50) == nil)
  }
}

@Suite("Spacing")
struct SmartSpacingTests {
  @Test func sentenceStartOrMiddle() {
    #expect(SmartSpacing.insertion(textBefore: nil) == .start)
    #expect(SmartSpacing.insertion(textBefore: "") == .start)
    #expect(SmartSpacing.insertion(textBefore: "fatto. ") == .start)
    #expect(SmartSpacing.insertion(textBefore: "riga\n") == .start)
    #expect(SmartSpacing.insertion(textBefore: "ciao ") == .mid)
    #expect(SmartSpacing.insertion(textBefore: "allora,") == .mid)
  }

  @Test func leadingSpace() {
    #expect(SmartSpacing.adjust("ci vediamo", textBefore: "ciao") == " ci vediamo")
    #expect(SmartSpacing.adjust("ci vediamo", textBefore: "ciao ") == "ci vediamo")
    #expect(SmartSpacing.adjust("Ci vediamo", textBefore: "fatto.") == " Ci vediamo")
    #expect(SmartSpacing.adjust(", poi", textBefore: "ciao") == ", poi")
    #expect(SmartSpacing.adjust("nota", textBefore: "(") == "nota")
    #expect(SmartSpacing.adjust("ciao", textBefore: nil) == "ciao")
    #expect(SmartSpacing.adjust("ciao", textBefore: "riga\n") == "ciao")
  }
}
