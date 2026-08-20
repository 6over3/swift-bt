/// Executes an application's typed behavior leaves.
///
/// Implementations may satisfy these asynchronous requirements with ordinary
/// synchronous methods when a leaf does not need to suspend. This keeps leaf
/// modeling independent from whether the tree is continuously or host driven.
public protocol BehaviorExecutor: Sendable {
  associatedtype Action: Sendable
  associatedtype Condition: Sendable
  associatedtype Context: Sendable

  /// Evaluates a condition against the current application context.
  func evaluate(
    _ condition: Condition,
    in context: Context
  ) async throws -> BehaviorConditionResult

  /// Performs an action and returns an expected behavior-tree decision.
  func perform(
    _ action: Action,
    in context: Context,
    reporting: BehaviorReporter
  ) async throws -> BehaviorActionResult
}

/// The terminal result of one complete tree execution.
public struct BehaviorRunResult: Codable, Hashable, Sendable {
  public let executionID: BehaviorExecutionID
  public let outcome: BehaviorOutcome
  public let diagnostic: BehaviorDiagnostic?

  /// Creates a terminal run result.
  public init(
    executionID: BehaviorExecutionID,
    outcome: BehaviorOutcome,
    diagnostic: BehaviorDiagnostic? = nil
  ) {
    self.executionID = executionID
    self.outcome = outcome
    self.diagnostic = diagnostic
  }
}

/// Identifies the node at which an executor or hook threw an error.
public struct BehaviorExecutionError: Error, Sendable {
  public let nodeID: BehaviorNodeID
  public let underlyingError: any Error

  /// Creates a contextual execution error without erasing its underlying error.
  public init(nodeID: BehaviorNodeID, underlyingError: any Error) {
    self.nodeID = nodeID
    self.underlyingError = underlyingError
  }
}

/// A runtime capability required by a tree was not supplied by its driver.
public enum BehaviorRuntimeError: Error, Equatable, Sendable {
  case reactiveExecutionRequiresWakeUpSource
}
