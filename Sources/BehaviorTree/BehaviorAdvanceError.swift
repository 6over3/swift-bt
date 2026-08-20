/// A problem with a host-driven execution request or saved cursor.
public enum BehaviorAdvanceError: Error, Equatable, Sendable {
  case negativeElapsed
  case snapshotTreeMismatch(
    expectedName: String,
    expectedVersion: String,
    actualName: String,
    actualVersion: String
  )
  case invalidSnapshot
  case cancellationHookDidNotComplete(nodeID: BehaviorNodeID)
  case cancellationHookFailed(nodeID: BehaviorNodeID)
}
