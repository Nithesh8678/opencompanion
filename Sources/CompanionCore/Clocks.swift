import Foundation

/// Integrates active monotonic time; pausing and changing speed always rebase the epoch.
public struct AnimationClock: Codable, Equatable, Sendable {
  public private(set) var phase: Double = 0
  public private(set) var speed: Double = 1
  public private(set) var isPlaying = true
  private var epoch: Double
  public init(
    at monotonicTime: Double = 0, phase: Double = 0, speed: Double = 1, isPlaying: Bool = true
  ) {
    self.epoch = monotonicTime
    self.phase = phase
    self.speed = speed
    self.isPlaying = isPlaying
  }
  public func value(at monotonicTime: Double) throws -> Double {
    guard monotonicTime.isFinite, epoch.isFinite, monotonicTime >= epoch, phase.isFinite,
      speed.isFinite,
      speed >= 0, speed <= 16
    else { throw CoreError.invalidTransition("animation clock/time range") }
    let value = phase + (isPlaying ? (monotonicTime - epoch) * speed : 0)
    guard value.isFinite else { throw CoreError.invalidTransition("animation time overflow") }
    return value
  }
  public mutating func setPlaying(_ playing: Bool, at time: Double) throws {
    phase = try value(at: time)
    epoch = time
    isPlaying = playing
  }
  public mutating func setSpeed(_ speed: Double, at time: Double) throws {
    guard speed.isFinite, (0...16).contains(speed) else {
      throw CoreError.invalidTransition("speed range")
    }
    phase = try value(at: time)
    epoch = time
    self.speed = speed
  }
  public mutating func step(by interval: Double, at time: Double) throws {
    guard interval.isFinite, interval >= 0, interval <= 60 else {
      throw CoreError.invalidTransition("step range")
    }
    phase = try value(at: time) + interval
    epoch = time
    isPlaying = false
  }
  public mutating func replay(at time: Double) throws {
    _ = try value(at: time)
    epoch = time
    phase = 0
  }
}

public struct NarrationBeat: Codable, Equatable, Identifiable, Sendable {
  public enum Policy: String, Codable, Sendable { case visualFirst, speechSynchronized, textOnly }
  public var id, text, surfaceID: String
  public var generation, requiredDocumentRevision: Int
  public var dependsOnNodeIDs: [String]
  public var policy: Policy
  public var releaseAtPlaybackSeconds: Double
  public init(
    id: String, text: String, surfaceID: String, generation: Int, requiredDocumentRevision: Int,
    dependsOnNodeIDs: [String] = [], policy: Policy = .visualFirst,
    releaseAtPlaybackSeconds: Double = 0
  ) {
    self.id = id
    self.text = text
    self.surfaceID = surfaceID
    self.generation = generation
    self.requiredDocumentRevision = requiredDocumentRevision
    self.dependsOnNodeIDs = dependsOnNodeIDs
    self.policy = policy
    self.releaseAtPlaybackSeconds = releaseAtPlaybackSeconds
  }
}

/// Only host playback progress releases speech-synchronized beats. Packet arrival is not a clock.
public struct BeatScheduler: Sendable {
  public private(set) var generation: Int
  public private(set) var playbackSeconds: Double = 0
  public private(set) var enginePlaybackComplete = false
  public private(set) var generationComplete = false
  public private(set) var releasedIDs: Set<String> = []
  private var committed: [NarrationBeat] = []
  private var fallbackStart: Double?
  private var hasPlaybackProgress = false
  public init(generation: Int) { self.generation = generation }
  public mutating func commit(_ beat: NarrationBeat, against document: SceneDocument) throws {
    guard beat.generation == generation else { throw CoreError.staleGeneration }
    guard !committed.contains(where: { $0.id == beat.id }) else {
      throw CoreError.duplicateID(beat.id)
    }
    guard committed.count < 256, beat.text.utf8.count <= 16_384 else {
      throw CoreError.budgetExceeded("narration beats")
    }
    guard !beat.id.isEmpty, !beat.text.isEmpty, beat.surfaceID == document.id,
      beat.requiredDocumentRevision <= document.revision,
      beat.requiredDocumentRevision >= 0, beat.releaseAtPlaybackSeconds.isFinite,
      beat.releaseAtPlaybackSeconds >= 0,
      beat.dependsOnNodeIDs.allSatisfy({ id in document.nodes.contains { $0.id == id } })
    else { throw CoreError.invalidEvent("beat dependencies/revision") }
    committed.append(beat)
  }
  public mutating func hostPlaybackProgress(seconds: Double, generation: Int) throws {
    guard generation == self.generation else { throw CoreError.staleGeneration }
    guard seconds.isFinite, seconds >= playbackSeconds else {
      throw CoreError.invalidEvent("playback must be monotonic")
    }
    playbackSeconds = seconds
    hasPlaybackProgress = true
  }
  public mutating func hostPlaybackCompleted(generation: Int) throws {
    guard generation == self.generation else { throw CoreError.staleGeneration }
    enginePlaybackComplete = true
  }
  public mutating func markGenerationComplete() { generationComplete = true }
  public mutating func useTextFallback(at monotonicTime: Double) throws {
    guard monotonicTime.isFinite else { throw CoreError.invalidEvent("fallback clock") }
    fallbackStart = monotonicTime
  }
  public mutating func releaseReady(at monotonicTime: Double) throws -> [NarrationBeat] {
    guard monotonicTime.isFinite else { throw CoreError.invalidEvent("release clock") }
    let textSeconds = fallbackStart.map { max(0, monotonicTime - $0) }
    let ready = committed.filter { beat in
      !releasedIDs.contains(beat.id)
        && (beat.policy != .speechSynchronized
          || ((hasPlaybackProgress || textSeconds != nil)
            && max(playbackSeconds, textSeconds ?? 0) >= beat.releaseAtPlaybackSeconds))
    }
    releasedIDs.formUnion(ready.map(\.id))
    return ready
  }
  public mutating func cancel(to newGeneration: Int) throws {
    guard newGeneration > generation else {
      throw CoreError.invalidEvent("cancellation generation must advance")
    }
    self = BeatScheduler(generation: newGeneration)
  }
  public var visualComplete: Bool { committed.allSatisfy { releasedIDs.contains($0.id) } }
}
