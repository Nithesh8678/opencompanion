import AppKit

/// A camera cutout can route pointer movement through the menu bar rather than
/// an application's mouse event stream. Read the logical pointer position on the
/// common run loop as a fallback; this neither captures the screen nor monitors
/// keyboard input, and does not need Accessibility or Input Monitoring access.
@MainActor final class NotchPointerPolling {
  static let interval: TimeInterval = 0.05

  private let location: @MainActor () -> CGPoint
  private let onSample: @MainActor (CGPoint) -> Void
  private var timer: Timer?

  var isRunning: Bool { timer != nil }

  init(
    location: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
    onSample: @escaping @MainActor (CGPoint) -> Void
  ) {
    self.location = location
    self.onSample = onSample
  }

  func start() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
      let finished = MainActor.assumeIsolated {
        guard let self else { return true }
        self.sample()
        return false
      }
      if finished { timer.invalidate() }
    }
    timer.tolerance = Self.interval / 4
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    sample()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func sample() { onSample(location()) }
}
