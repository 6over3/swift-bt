import Foundation
import Synchronization
import Testing

@testable import BehaviorTree

private enum HostAction: Hashable, Sendable {
  case immediate(String)
  case delayed(String, Duration)
  case fail(String)
  case setAllowed(Bool)
}

private enum HostCondition: Hashable, Sendable {
  case highPriority
  case allowed
}

@MainActor
private final class HostContext {
  var highPriority = false
  var allowed = true
  var actionCalls: [String: Int] = [:]
  var conditionCalls: [HostCondition: Int] = [:]
  var completions: [String] = []
}

@MainActor
private struct HostExecutor: BehaviorExecutor {
  func evaluate(
    _ condition: HostCondition,
    in context: HostContext
  ) throws -> BehaviorConditionResult {
    context.conditionCalls[condition, default: 0] += 1
    let accepted =
      switch condition {
      case .highPriority: context.highPriority
      case .allowed: context.allowed
      }
    return accepted ? .satisfied : .unsatisfied(code: "test.condition-false")
  }

  func perform(
    _ action: HostAction,
    in context: HostContext,
    reporting: BehaviorReporter
  ) async throws -> BehaviorActionResult {
    switch action {
    case .immediate(let name):
      context.actionCalls[name, default: 0] += 1
      context.completions.append(name)
      return .succeeded
    case .delayed(let name, let duration):
      context.actionCalls[name, default: 0] += 1
      try await Task.sleep(for: duration)
      await reporting.report(fraction: 1, message: name)
      context.completions.append(name)
      return .succeeded
    case .fail(let name):
      context.actionCalls[name, default: 0] += 1
      return .failed
    case .setAllowed(let allowed):
      context.allowed = allowed
      return .succeeded
    }
  }

}

@MainActor
@Test
func hostAdvancesOnlyWhenAskedAndAwaitsAsyncLeaves() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "host-driven") {
    Sequence {
      Condition(.allowed)
      Wait(for: .milliseconds(100))
      Action(.delayed("publish", .milliseconds(1)))
    }
  }
  let context = HostContext()
  let executor = HostExecutor()
  var execution = tree.makeExecution()

  #expect(
    try await execution.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(30)
    ) == .running
  )
  #expect(context.actionCalls["publish"] == nil)
  #expect(
    try await execution.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(70)
    ) == .succeeded
  )
  #expect(context.completions == ["publish"])
  #expect(context.conditionCalls[.allowed] == 1)
  #expect(try await execution.advance(in: context, using: executor) == .succeeded)
  #expect(context.actionCalls["publish"] == 1)
}

@MainActor
@Test
func hostDrivenExecutionAdvancesThroughReusableSubtrees() async throws {
  let reusable = try BehaviorTree<HostAction, HostCondition>(name: "reusable") {
    Sequence {
      Wait(for: .milliseconds(50))
      Action(.immediate("inside"))
    }
  }
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "parent") {
    Subtree(reusable)
  }
  let context = HostContext()
  var execution = tree.makeExecution()

  #expect(
    try await execution.advance(
      in: context,
      using: HostExecutor(),
      elapsed: .milliseconds(20)
    ) == .running
  )
  let snapshot = try JSONDecoder().decode(
    BehaviorExecutionSnapshot.self,
    from: JSONEncoder().encode(execution.snapshot())
  )
  let changedReusable = try BehaviorTree<HostAction, HostCondition>(
    name: "reusable",
    version: "2"
  ) {
    Sequence {
      Wait(for: .milliseconds(50))
      Action(.immediate("inside"))
    }
  }
  let changedTree = try BehaviorTree<HostAction, HostCondition>(name: "parent") {
    Subtree(changedReusable)
  }
  #expect(throws: BehaviorAdvanceError.invalidSnapshot) {
    try changedTree.makeExecution(restoring: snapshot)
  }
  execution = try tree.makeExecution(restoring: snapshot)
  #expect(
    try await execution.advance(
      in: context,
      using: HostExecutor(),
      elapsed: .milliseconds(30)
    ) == .succeeded
  )
  #expect(context.completions == ["inside"])
}

@MainActor
@Test
func waitCanResumeFromASnapshot() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(
    name: "checkpointed",
    version: "2"
  ) {
    Wait(for: .milliseconds(100))
  }
  let context = HostContext()
  let executor = HostExecutor()
  var original = tree.makeExecution()

  #expect(
    try await original.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(30)
    ) == .running
  )
  let encoded = try JSONEncoder().encode(original.snapshot())
  let snapshot = try JSONDecoder().decode(BehaviorExecutionSnapshot.self, from: encoded)
  var restored = try tree.makeExecution(restoring: snapshot)

  #expect(
    try await restored.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(70)
    ) == .succeeded
  )
  #expect(restored.executionID == original.executionID)
}

@MainActor
@Test
func sequentialWaitsShareOneElapsedTimeBudget() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "time-budget") {
    Sequence {
      Wait(for: .milliseconds(50))
      Wait(for: .milliseconds(50))
    }
  }
  let context = HostContext()
  let executor = HostExecutor()
  var execution = tree.makeExecution()

  #expect(
    try await execution.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(75)
    ) == .running
  )
  #expect(
    try await execution.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(25)
    ) == .succeeded
  )
}

@MainActor
@Test
func reactiveSelectorPreemptsItsLowerPriorityBranch() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "reactive") {
    Selector(memory: .reactive) {
      Sequence {
        Condition(.highPriority)
        Action(.immediate("high"))
      }
      Lifecycle(onCancel: .immediate("low-cancel")) {
        WaitForever()
      }
    }
  }
  let context = HostContext()
  let executor = HostExecutor()
  var execution = tree.makeExecution()

  #expect(try await execution.advance(in: context, using: executor) == .running)
  context.highPriority = true
  #expect(try await execution.advance(in: context, using: executor) == .succeeded)
  #expect(context.completions == ["high", "low-cancel"])
  #expect(context.conditionCalls[.highPriority] == 2)
}

@MainActor
@Test
func hostDrivenParallelAdvancesEveryRunningChild() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "parallel") {
    WhenAll {
      Wait(for: .milliseconds(50))
      Wait(for: .milliseconds(100))
    }
  }
  let context = HostContext()
  let executor = HostExecutor()
  var execution = tree.makeExecution()

  #expect(
    try await execution.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(50)
    ) == .running
  )
  #expect(
    try await execution.advance(
      in: context,
      using: executor,
      elapsed: .milliseconds(50)
    ) == .succeeded
  )
}

@MainActor
@Test
func cancellationRunsLifecycleHooksExactlyOnce() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "cancel-hooks") {
    Lifecycle(
      onCancel: .immediate("cancel-hook"),
      onExit: .immediate("exit-hook")
    ) {
      WaitForever()
    }
  }
  let context = HostContext()
  let executor = HostExecutor()
  var execution = tree.makeExecution()

  #expect(try await execution.advance(in: context, using: executor) == .running)
  try await execution.cancel(in: context, using: executor)

  #expect(execution.status == .cancelled)
  #expect(context.completions == ["cancel-hook", "exit-hook"])
}

@MainActor
@Test
func corruptSnapshotsAreRejectedBeforeExecution() throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "snapshot-validation") {
    Sequence {
      Action(.immediate("one"))
      Action(.immediate("two"))
    }
  }
  let valid = tree.makeExecution().snapshot()
  let corrupt = BehaviorExecutionSnapshot(
    treeName: valid.treeName,
    treeVersion: valid.treeVersion,
    executionID: valid.executionID,
    definitionFingerprint: valid.definitionFingerprint,
    status: .running,
    eventSequence: valid.eventSequence,
    elapsedNanoseconds: valid.elapsedNanoseconds,
    nodes: [
      .root: BehaviorNodeSnapshot(status: .running, runtimeState: .cursor(999))
    ]
  )

  #expect(throws: BehaviorAdvanceError.invalidSnapshot) {
    try tree.makeExecution(restoring: corrupt)
  }
}

@MainActor
@Test
func restoringAnIdleSnapshotEmitsExecutionStarted() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "idle") {
    Action(.immediate("work"))
  }
  let events = Mutex<[BehaviorEvent]>([])
  let observer = BehaviorObserver { event in
    events.withLock { $0.append(event) }
  }
  var execution = try tree.makeExecution(
    restoring: tree.makeExecution().snapshot(),
    observing: [observer]
  )
  let context = HostContext()

  #expect(try await execution.advance(in: context, using: HostExecutor()) == .succeeded)
  #expect(events.withLock { $0.first?.phase } == .executionStarted)
}

@MainActor
@Test
func decoratorsBranchesAndSkippedPreconditionsCompose() async throws {
  let tree = try BehaviorTree<HostAction, HostCondition>(name: "composition") {
    Sequence {
      Invert { Action(.fail("inverted")) }
      ForceSuccess { Action(.fail("forced")) }
      Precondition(.allowed, otherwise: .skip) {
        Action(.immediate("must-not-run"))
      }
      If(.allowed) {
        Action(.immediate("then"))
      } else: {
        Action(.immediate("else"))
      }
      Repeat(count: 2) {
        Action(.immediate("repeated"))
      }
      UntilFailure {
        Action(.fail("until-failure"))
      }
    }
  }
  let context = HostContext()
  context.allowed = false
  let executor = HostExecutor()
  var execution = tree.makeExecution()

  #expect(try await execution.advance(in: context, using: executor) == .running)
  #expect(try await execution.advance(in: context, using: executor) == .succeeded)
  #expect(context.actionCalls["must-not-run"] == nil)
  #expect(context.actionCalls["then"] == nil)
  #expect(context.actionCalls["else"] == 1)
  #expect(context.actionCalls["repeated"] == 2)
  #expect(context.actionCalls["until-failure"] == 1)
}

@MainActor
@Test
func whileAndWhileAllHaveDistinctConditionBoundaries() async throws {
  let interruptible = try BehaviorTree<HostAction, HostCondition>(name: "while") {
    While(.allowed) {
      Action(.setAllowed(false))
      Action(.immediate("interruptible-tail"))
    }
  }
  let completeIteration = try BehaviorTree<HostAction, HostCondition>(name: "while-all") {
    WhileAll(.allowed) {
      Action(.setAllowed(false))
      Action(.immediate("complete-tail"))
    }
  }
  let executor = HostExecutor()
  let interruptibleContext = HostContext()
  var interruptibleExecution = interruptible.makeExecution()
  #expect(
    try await interruptibleExecution.advance(
      in: interruptibleContext,
      using: executor
    ) == .running
  )
  #expect(
    try await interruptibleExecution.advance(
      in: interruptibleContext,
      using: executor
    ) == .failed
  )
  #expect(interruptibleContext.actionCalls["interruptible-tail"] == nil)

  let completeContext = HostContext()
  var completeExecution = completeIteration.makeExecution()
  #expect(
    try await completeExecution.advance(in: completeContext, using: executor) == .running
  )
  #expect(
    try await completeExecution.advance(in: completeContext, using: executor) == .running
  )
  #expect(
    try await completeExecution.advance(in: completeContext, using: executor) == .failed
  )
  #expect(completeContext.actionCalls["complete-tail"] == 1)
}
