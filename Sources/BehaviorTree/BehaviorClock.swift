/// A sendable, type-erased Swift clock used by asynchronous tree scheduling.
public struct BehaviorClock: Sendable {
  private let sleepOperation: @Sendable (Duration) async throws -> Void

  /// The monotonic clock used by default for waits, retry backoff, and timeouts.
  public static let continuous = Self(ContinuousClock())

  /// Erases a Swift ``Clock`` whose duration is ``Duration``.
  public init<ClockType: Clock>(_ clock: ClockType)
  where ClockType.Duration == Duration {
    sleepOperation = { duration in
      try await clock.sleep(for: duration)
    }
  }

  /// Creates a clock from a cancellation-aware sleep operation.
  ///
  /// This initializer is useful for deterministic tests and host schedulers.
  public init(
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    sleepOperation = sleep
  }

  /// Suspends for a duration according to this clock.
  public func sleep(for duration: Duration) async throws {
    try await sleepOperation(duration)
  }
}

enum BehaviorRuntimeClock {
  @TaskLocal static var current = BehaviorClock.continuous
}

func suspendUntilCancelled() async throws -> Never {
  let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
  defer { continuation.finish() }
  for await _ in stream {}
  throw CancellationError()
}
