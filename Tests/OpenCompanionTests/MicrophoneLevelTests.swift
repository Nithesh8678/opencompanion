import AVFoundation
import Foundation
import Testing

@testable import OpenCompanion

@Suite struct MicrophoneLevelTests {
  @Test func rmsDistinguishesSilenceSpeechAmplitudeAndTwoChannels() {
    let silence = MicrophoneRMS.calculate(frameCount: 1_024, channelCount: 1) { _, _ in 0 }
    let quiet = MicrophoneRMS.calculate(frameCount: 1_024, channelCount: 1) { _, _ in 0.02 }
    let louder = MicrophoneRMS.calculate(frameCount: 1_024, channelCount: 1) { _, _ in 0.2 }
    let stereo = MicrophoneRMS.calculate(frameCount: 4, channelCount: 2) { _, channel in
      channel == 0 ? 1 : 0
    }
    #expect(silence == 0)
    #expect(abs(quiet - 0.02) < 0.000_001)
    #expect(louder > quiet)
    #expect(abs(stereo - sqrt(0.5)) < 0.000_001)
  }

  @Test func rmsSampleWorkIsBoundedEvenForExtremeFrameCounts() {
    var reads = 0
    var highestChannel = 0
    let value = MicrophoneRMS.calculate(frameCount: Int.max, channelCount: 64) { frame, channel in
      #expect(frame >= 0 && frame < Int.max)
      reads += 1
      highestChannel = max(highestChannel, channel)
      return 0.25
    }
    #expect(reads <= MicrophoneRMS.maximumSamples)
    #expect(highestChannel == 1)
    #expect(abs(value - 0.25) < 0.000_001)
    #expect(
      MicrophoneRMS.calculate(frameCount: 0, channelCount: 2) { _, _ in
        Issue.record("An empty buffer must not be read")
        return 1
      } == 0)
  }

  @Test func malformedSamplesCannotProduceNonfiniteOrUnboundedLevels() {
    let samples: [Double] = [.nan, .infinity, -.infinity, 2, -2]
    let value = MicrophoneRMS.calculate(frameCount: samples.count, channelCount: 1) { frame, _ in
      samples[frame]
    }
    #expect(value.isFinite && value >= 0 && value <= 1)
    var envelope = MicrophoneLevelEnvelope()
    for rms in [value, Double.nan, Double.infinity, -1, 10, 0] {
      let level = envelope.advance(rms: rms, elapsed: 0.04)
      #expect(level.isFinite && level >= 0 && level <= 1)
    }
  }

  @Test func realPCMBufferUsesBothNoninterleavedChannels() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
    buffer.frameLength = 128
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<128 {
      channels[0][frame] = 0.5
      channels[1][frame] = -0.5
    }
    #expect(abs(MicrophoneRMS.measure(buffer) - 0.5) < 0.000_001)
  }

  @Test func mailboxCoalescesPeaksWithoutRetainingBuffersOrQueuedWork() {
    let mailbox = MicrophoneLevelMailbox()
    mailbox.publish(rms: 0.2)
    mailbox.publish(rms: 0.8)
    mailbox.publish(rms: 0.4)
    mailbox.publish(rms: .nan)
    #expect(mailbox.consumePeak() == 0.8)
    #expect(mailbox.consumePeak() == 0)
    mailbox.publish(rms: 10)
    #expect(mailbox.consumePeak() == 1)
  }

  @Test func interleavedPCMChannelsUseTheFrameStride() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
    buffer.frameLength = 128
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<128 {
      channels[0][frame * 2] = 0.25
      channels[0][frame * 2 + 1] = -0.75
    }
    #expect(abs(MicrophoneRMS.measure(buffer) - sqrt(0.3125)) < 0.000_001)
  }

  @Test func envelopeRespondsToInputDecaysOnSilenceAndResetsImmediately() {
    var envelope = MicrophoneLevelEnvelope()
    #expect(envelope.advance(rms: 0, elapsed: 0.04) == 0)
    let first = envelope.advance(rms: 0.1, elapsed: 0.04)
    let second = envelope.advance(rms: 0.1, elapsed: 0.04)
    #expect(first > 0 && second > first)
    var previous = second
    for _ in 0..<30 {
      let current = envelope.advance(rms: 0, elapsed: 0.04)
      #expect(current <= previous)
      previous = current
    }
    #expect(previous == 0)
    _ = envelope.advance(rms: 1, elapsed: 0.04)
    envelope.reset()
    #expect(envelope.level == 0)
  }
}
