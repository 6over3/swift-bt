import Foundation
import Synchronization
import Testing

@testable import BehaviorTree

private enum RuntimeTestAction: Sendable {
  case succeed(String)
  case fail(String, String)
  case delayedFailure(String, String, Duration)
  case delayedSuccess(String, Duration)
  case retryUntil(Int)
  case cancellationHook
  case exitHook
}

private enum RuntimeTestCondition: Sendable {
  case accepted
  case rejected
  case contextFlag
}

private actor RuntimeTestContext {
  private(set) var performed: [String] = []
  private(set) var cancelled: [String] = []
  private(set) var retryAttempts = 0
  private var flag = false

  func record(_ value: String) {
    performed.append(value)
  }

  func recordCancellation(_ value: String) {
    cancelled.append(value)
  }

  func nextRetryAttempt() -> Int {
    retryAttempts += 1
    return retryAttempts
  }

  func setFlag(_ value: Bool) {
    flag = value
  }

  func currentFlag() -> Bool {
    flag
  }
}

private struct RuntimeTestExecutor: BehaviorExecutor {
  func evaluate(
    _ condition: RuntimeTestCondition,
    in context: RuntimeTestContext
  ) async throws -> BehaviorConditionResult {
    switch condition {
    case .accepted:
      return .satisfied
    case .rejected:
      return .unsatisfied(
        code: "test.rejected",
        summary: "The test condition rejected the context",
        attributes: ["sample": .integer(42)]
      )
    case .contextFlag:
      return await context.currentFlag() ? .satisfied : .unsatisfied
    }
  }

  func perform(
    _ action: RuntimeTestAction,
    in context: RuntimeTestContext,
    reporting: BehaviorReporter
  ) async throws -> BehaviorActionResult {
    switch action {
    case .succeed(let name):
      await context.record(name)
      return .succeeded

    case .fail(let name, let code):
      await context.record(name)
      return .failed(code: code)

    case .delayedFailure(let name, let code, let duration):
      await context.record("\(name):started")
      try await Task.sleep(for: duration)
      return .failed(code: code)

    case .delayedSuccess(let name, let duration):
      await context.record("\(name):started")
      do {
        try await Task.sleep(for: duration)
      } catch is CancellationError {
        await context.recordCancellation(name)
        throw CancellationError()
      }
      await reporting.report(fraction: 1, message: name)
      await context.record("\(name):finished")
      return .succeeded

    case .retryUntil(let requiredAttempt):
      let attempt = await context.nextRetryAttempt()
      return attempt >= requiredAttempt
        ? .succeeded
        : .failed(code: "test.retry", attributes: ["attempt": .integer(Int64(attempt))])

    case .cancellationHook:
      await context.record("cancel-hook")
      return .succeeded

    case .exitHook:
      await context.record("exit-hook")
      return .succeeded
    }
  }
}

private final class EventRecorder: Sendable {
  private let storage = Mutex<[BehaviorEvent]>([])

  var observer: BehaviorObserver {
    BehaviorObserver { [weak self] event in
      guard let self else { return }
      storage.withLock { $0.append(event) }
    }
  }

  var events: [BehaviorEvent] {
    storage.withLock { $0 }
  }
}

@Test
func asyncSequenceExposesTheRejectedConditionReason() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "decision") {
    Sequence {
      Action(.succeed("before"))
      Condition(.rejected, named: "permission")
      Action(.succeed("after"))
    }
  }
  let context = RuntimeTestContext()
  let recorder = EventRecorder()

  let result = try await tree.run(
    in: context,
    using: RuntimeTestExecutor(),
    observing: [recorder.observer]
  )

  #expect(result.outcome == .failed)
  #expect(result.diagnostic?.code == "test.rejected")
  #expect(await context.performed == ["before"])
  let rejection = recorder.events.first {
    $0.nodeID?.rawValue == "root.1" && $0.phase == .nodeFailed
  }
  #expect(rejection?.label == "permission")
  #expect(rejection?.diagnostic?.attributes["sample"] == .integer(42))
}

@Test
func subtreeExecutesTransparentlyAndEmitsItsNamedBoundary() async throws {
  let reusable = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(
    name: "reusable-work",
    version: "2"
  ) {
    Sequence {
      Action(.succeed("inside"))
      Condition(.accepted)
    }
  }
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "parent") {
    Sequence {
      Action(.succeed("before"))
      Subtree(reusable)
      Action(.succeed("after"))
    }
  }
  let context = RuntimeTestContext()
  let recorder = EventRecorder()

  let result = try await tree.run(
    in: context,
    using: RuntimeTestExecutor(),
    observing: [recorder.observer]
  )

  #expect(result.outcome == .succeeded)
  #expect(await context.performed == ["before", "inside", "after"])
  let boundary = recorder.events.first {
    $0.nodeID?.rawValue == "root.1" && $0.phase == .nodeEntered
  }
  #expect(boundary?.nodeKind == .subtree)
  #expect(boundary?.label == "reusable-work")
  #expect(boundary?.attributes["treeVersion"] == .string("2"))
}

@Test
func whenAnyCancelsUnfinishedSiblingsWithoutReplacingTheWinner() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "first-success") {
    WhenAny {
      Action(.delayedSuccess("fast", .milliseconds(5)))
      Action(.delayedSuccess("slow", .seconds(5)))
    }
  }
  let context = RuntimeTestContext()

  let result = try await tree.run(in: context, using: RuntimeTestExecutor())

  #expect(result.outcome == .succeeded)
  #expect(await context.cancelled == ["slow"])
}

@Test
func raceReturnsTheFirstFailureAndCancelsTheOtherChild() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "race") {
    Race {
      Action(.delayedFailure("failed-first", "test.first", .milliseconds(5)))
      Action(.delayedSuccess("slow", .seconds(5)))
    }
  }
  let context = RuntimeTestContext()

  let result = try await tree.run(in: context, using: RuntimeTestExecutor())

  #expect(result.outcome == .failed)
  #expect(result.diagnostic?.code == "test.first")
  #expect(await context.cancelled == ["slow"])
}

@Test
func retryResetsAndRunsTheLeafUntilSuccess() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "retry") {
    Retry(maximumAttempts: 3) {
      Action(.retryUntil(3))
    }
  }
  let context = RuntimeTestContext()
  let recorder = EventRecorder()

  let result = try await tree.run(
    in: context,
    using: RuntimeTestExecutor(),
    observing: [recorder.observer]
  )

  #expect(result.outcome == .succeeded)
  #expect(await context.retryAttempts == 3)
  #expect(
    recorder.events.filter { $0.phase == .nodeRetrying }.map(\.attempt) == [2, 3]
  )
  #expect(
    recorder.events.filter {
      $0.nodeID?.rawValue == "root.0" && $0.phase == .nodeEntered
    }.map(\.activation) == [1, 2, 3]
  )
}

@Test
func timeoutRunsCancellationAndExitHooks() async throws {
  let guarded: ActionLifecycleComponent<RuntimeTestAction> = Action(
    .delayedSuccess("work", .seconds(5))
  ).onLifecycle(cancel: .cancellationHook, exit: .exitHook)
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "timeout") {
    Timeout(.milliseconds(10)) {
      guarded
    }
  }
  let context = RuntimeTestContext()
  let recorder = EventRecorder()

  let result = try await tree.run(
    in: context,
    using: RuntimeTestExecutor(),
    observing: [recorder.observer]
  )

  #expect(result.outcome == .failed)
  #expect(result.diagnostic?.code == "behavior.timeout")
  #expect(await context.cancelled == ["work"])
  #expect(await context.performed.contains("cancel-hook"))
  #expect(await context.performed.contains("exit-hook"))
  #expect(recorder.events.contains { $0.phase == .nodeTimedOut })
}

@Test
func asyncReactiveTreesRequireAnExplicitWakeUpRuntime() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "reactive") {
    Selector(memory: .reactive) {
      Condition(.accepted)
      Action(.succeed("fallback"))
    }
  }

  await #expect(throws: BehaviorRuntimeError.reactiveExecutionRequiresWakeUpSource) {
    try await tree.run(in: RuntimeTestContext(), using: RuntimeTestExecutor())
  }
}

@Test
func observableExecutionReevaluatesReactivePriorityAfterInvalidation() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "reactive") {
    Selector(memory: .reactive) {
      Sequence {
        Condition(.contextFlag)
        Action(.succeed("high"))
      }
      Action(.delayedSuccess("low", .seconds(5)))
    }
  }
  let context = RuntimeTestContext()
  let execution = tree.start(in: context, using: RuntimeTestExecutor())

  try await Task.sleep(for: .milliseconds(10))
  await context.setFlag(true)
  await execution.invalidate()
  let result = try await execution.value

  #expect(result.outcome == .succeeded)
  #expect(await context.cancelled == ["low"])
  #expect(await context.performed.contains("high"))
}

@Test
func customClockDrivesWaitsAndRetryBackoff() async throws {
  actor Sleeper {
    var durations: [Duration] = []
    func sleep(for duration: Duration) { durations.append(duration) }
  }

  let sleeper = Sleeper()
  let clock = BehaviorClock { duration in
    await sleeper.sleep(for: duration)
  }
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "clock") {
    Sequence {
      Wait(for: .seconds(1))
      Retry(maximumAttempts: 2, backoff: .seconds(2)) {
        Action(.retryUntil(2))
      }
    }
  }

  let result = try await tree.run(
    in: RuntimeTestContext(),
    using: RuntimeTestExecutor(),
    clock: clock
  )

  #expect(result.outcome == .succeeded)
  #expect(await sleeper.durations == [.seconds(1), .seconds(2)])
}

@Test
func asyncDecoratorsBranchesAndSkippedPreconditionsCompose() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "composition") {
    Sequence {
      Invert { Action(.fail("inverted", "expected")) }
      ForceSuccess { Action(.fail("forced", "expected")) }
      Precondition(.rejected, otherwise: .skip) {
        Action(.succeed("must-not-run"))
      }
      If(.rejected) {
        Action(.succeed("then"))
      } else: {
        Action(.succeed("else"))
      }
      Repeat(count: 2) {
        Action(.succeed("repeated"))
      }
      UntilFailure {
        Action(.fail("until-failure", "expected"))
      }
    }
  }
  let context = RuntimeTestContext()

  let result = try await tree.run(in: context, using: RuntimeTestExecutor())

  #expect(result.outcome == .succeeded)
  let performed = await context.performed
  #expect(!performed.contains("must-not-run"))
  #expect(!performed.contains("then"))
  #expect(performed.contains("else"))
  #expect(performed.filter { $0 == "repeated" }.count == 2)
  #expect(performed.contains("until-failure"))
}

@Test
func whenAllFailsFastAndAwaitsSiblingCancellation() async throws {
  let tree = try BehaviorTree<RuntimeTestAction, RuntimeTestCondition>(name: "all") {
    WhenAll {
      Action(.delayedFailure("failure", "test.failed", .milliseconds(1)))
      Action(.delayedSuccess("slow", .seconds(1)))
    }
  }
  let context = RuntimeTestContext()

  let result = try await tree.run(in: context, using: RuntimeTestExecutor())

  #expect(result.outcome == .failed)
  #expect(await context.cancelled == ["slow"])
}
