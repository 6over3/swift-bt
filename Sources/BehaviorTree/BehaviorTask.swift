/// A cancellable continuously driven run and its semantic event stream.
public struct BehaviorTask: Sendable {
  /// Runtime events in the order assigned by the execution.
  public let events: AsyncStream<BehaviorEvent>

  private let task: Task<BehaviorRunResult, any Error>
  private let invalidationSource: BehaviorInvalidationSource

  init(
    events: AsyncStream<BehaviorEvent>,
    task: Task<BehaviorRunResult, any Error>,
    invalidationSource: BehaviorInvalidationSource
  ) {
    self.events = events
    self.task = task
    self.invalidationSource = invalidationSource
  }

  /// Waits for the execution's terminal result.
  public var value: BehaviorRunResult {
    get async throws { try await task.value }
  }

  /// Requests cooperative cancellation of the execution and its descendants.
  public func cancel() {
    task.cancel()
  }

  /// Wakes reactive composites so they can reconsider higher-priority work.
  public func invalidate() async {
    await invalidationSource.invalidate()
  }
}

extension BehaviorTree where Action: Sendable, Condition: Sendable {
  /// Starts an observable execution without imposing a host event loop.
  ///
  /// The event stream keeps the newest `eventBufferCapacity` events when a
  /// consumer falls behind. Additional observers run on the execution path and
  /// should return promptly.
  public func start<Executor: BehaviorExecutor>(
    in context: Executor.Context,
    using executor: Executor,
    executionID: BehaviorExecutionID = .make(),
    clock: BehaviorClock = .continuous,
    eventBufferCapacity: Int = 1_024,
    observing observers: [BehaviorObserver] = []
  ) -> BehaviorTask
  where Executor.Action == Action, Executor.Condition == Condition {
    precondition(eventBufferCapacity > 0, "Event buffer capacity must be positive")
    let (events, continuation) = AsyncStream.makeStream(
      of: BehaviorEvent.self,
      bufferingPolicy: .bufferingNewest(eventBufferCapacity)
    )
    let streamObserver = BehaviorObserver { event in
      continuation.yield(event)
    }
    let invalidationSource = BehaviorInvalidationSource()
    let task = Task {
      defer { continuation.finish() }
      return try await runWithInvalidation(
        in: context,
        using: executor,
        executionID: executionID,
        clock: clock,
        observing: observers + [streamObserver],
        invalidationSource: invalidationSource
      )
    }
    return BehaviorTask(
      events: events,
      task: task,
      invalidationSource: invalidationSource
    )
  }
}
