/// A stable identifier for one execution of a tree.
public struct BehaviorExecutionID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  /// Creates an execution identifier from a persisted representation.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Creates a process-unique identifier suitable for telemetry and snapshots.
  public static func make() -> Self {
    func paddedHex(_ value: UInt64) -> String {
      let hex = String(value, radix: 16)
      return String(repeating: "0", count: 16 - hex.count) + hex
    }
    return Self(
      rawValue: paddedHex(UInt64.random(in: .min ... .max))
        + paddedHex(UInt64.random(in: .min ... .max))
    )
  }

  public var description: String { rawValue }
}

/// Quantified or descriptive progress reported by an action.
public struct BehaviorProgress: Codable, Hashable, Sendable {
  public let completed: Int64?
  public let total: Int64?
  public let fraction: Double?
  public let message: String?

  /// Creates a progress update without imposing a unit on the values.
  public init(
    completed: Int64? = nil,
    total: Int64? = nil,
    fraction: Double? = nil,
    message: String? = nil
  ) {
    self.completed = completed
    self.total = total
    self.fraction = fraction
    self.message = message
  }
}

/// Recursively structured, application-provided inspection data.
///
/// The behavior runtime does not interpret these values. Hosts can use them to
/// present request inputs, decisions, and result summaries without teaching the
/// behavior-tree package about application domain types.
public indirect enum BehaviorInspectionValue: Codable, Hashable, Sendable {
  case null
  case boolean(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([BehaviorInspectionValue])
  case object([String: BehaviorInspectionValue])
}

/// One ordered group of structured inspection data.
public struct BehaviorInspectionSection: Codable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let value: BehaviorInspectionValue

  public init(
    id: String,
    title: String,
    value: BehaviorInspectionValue
  ) {
    self.id = id
    self.title = title
    self.value = value
  }
}

/// An opaque application attachment associated with a behavior node.
///
/// The identifier is meaningful only to the host. Swift-BT never opens,
/// persists, uploads, or interprets the referenced content.
public struct BehaviorInspectionAttachment: Codable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let role: String?
  public let contentType: String?
  public let byteCount: Int64?
  public let attributes: [String: BehaviorMetadataValue]

  public init(
    id: String,
    label: String,
    role: String? = nil,
    contentType: String? = nil,
    byteCount: Int64? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) {
    self.id = id
    self.label = label
    self.role = role
    self.contentType = contentType
    self.byteCount = byteCount
    self.attributes = attributes
  }
}

/// The application-visible result of a successfully executed behavior.
///
/// Execution status and result meaning are intentionally separate. An action
/// can complete normally without producing a match, while a produced result
/// can still be inspected independently from the runtime's success state.
public enum BehaviorInspectionOutcome: String, Codable, Hashable, Sendable {
  /// The behavior completed, but it does not claim that it produced a value.
  case completed

  /// The behavior produced one or more application-meaningful values.
  case produced

  /// The behavior completed normally and found no applicable value.
  case noResult
}

/// A deliberately selected projection of application state for inspection.
///
/// Domain values and mutable workflow state remain in the executor context.
/// Keep inspections small and exclude secrets or sensitive values because they
/// may be displayed, serialized, logged, or sent to a tracing backend.
public struct BehaviorInspection: Codable, Hashable, Sendable {
  public let summary: String?
  public let outcome: BehaviorInspectionOutcome?
  public let values: [String: BehaviorMetadataValue]
  public let sections: [BehaviorInspectionSection]
  public let attachments: [BehaviorInspectionAttachment]

  /// Creates a node-scoped inspection projection.
  public init(
    summary: String? = nil,
    outcome: BehaviorInspectionOutcome? = nil,
    values: [String: BehaviorMetadataValue] = [:],
    sections: [BehaviorInspectionSection] = [],
    attachments: [BehaviorInspectionAttachment] = []
  ) {
    self.summary = summary
    self.outcome = outcome
    self.values = values
    self.sections = sections
    self.attachments = attachments
  }
}

/// The semantic transition represented by an execution event.
public enum BehaviorEventPhase: String, Codable, Hashable, Sendable {
  case executionStarted
  case executionCompleted
  case executionFailed
  case executionCancelled
  case nodeEntered
  case nodeRunning
  case nodeSucceeded
  case nodeFailed
  case nodeSkipped
  case nodeCancelled
  case nodeProgress
  case nodeInspected
  case nodeRetrying
  case nodeTimedOut
  case nodeReset
}

/// One ordered, data-only execution event.
public struct BehaviorEvent: Codable, Hashable, Sendable {
  public let treeName: String
  public let treeVersion: String
  public let executionID: BehaviorExecutionID
  public let sequence: UInt64
  public let nodeID: BehaviorNodeID?
  public let activation: UInt64?
  public let attempt: Int?
  public let parentID: BehaviorNodeID?
  public let childRole: BehaviorChildRole?
  public let nodeKind: BehaviorNodeKind?
  public let label: String?
  public let attributes: [String: BehaviorMetadataValue]
  public let phase: BehaviorEventPhase
  public let outcome: BehaviorOutcome?
  public let diagnostic: BehaviorDiagnostic?
  public let progress: BehaviorProgress?
  public let inspection: BehaviorInspection?
  public let elapsedNanoseconds: Int64

  /// Creates a semantic execution event.
  public init(
    treeName: String,
    treeVersion: String,
    executionID: BehaviorExecutionID,
    sequence: UInt64,
    nodeID: BehaviorNodeID? = nil,
    activation: UInt64? = nil,
    attempt: Int? = nil,
    parentID: BehaviorNodeID? = nil,
    childRole: BehaviorChildRole? = nil,
    nodeKind: BehaviorNodeKind? = nil,
    label: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:],
    phase: BehaviorEventPhase,
    outcome: BehaviorOutcome? = nil,
    diagnostic: BehaviorDiagnostic? = nil,
    progress: BehaviorProgress? = nil,
    inspection: BehaviorInspection? = nil,
    elapsedNanoseconds: Int64
  ) {
    self.treeName = treeName
    self.treeVersion = treeVersion
    self.executionID = executionID
    self.sequence = sequence
    self.nodeID = nodeID
    self.activation = activation
    self.attempt = attempt
    self.parentID = parentID
    self.childRole = childRole
    self.nodeKind = nodeKind
    self.label = label
    self.attributes = attributes
    self.phase = phase
    self.outcome = outcome
    self.diagnostic = diagnostic
    self.progress = progress
    self.inspection = inspection
    self.elapsedNanoseconds = elapsedNanoseconds
  }
}

/// A lightweight destination for semantic behavior-tree events.
public struct BehaviorObserver: Sendable {
  private let receiveEvent: @Sendable (BehaviorEvent) -> Void

  /// Creates an observer. The callback must return promptly.
  public init(_ receiveEvent: @escaping @Sendable (BehaviorEvent) -> Void) {
    self.receiveEvent = receiveEvent
  }

  func receive(_ event: BehaviorEvent) {
    receiveEvent(event)
  }
}

/// Reports progress and inspection data from an action.
public struct BehaviorReporter: Sendable {
  /// The exact action node receiving reports and executing host work.
  ///
  /// Hosts can use this stable identifier to attach externally persisted child
  /// executions or artifacts to the declaring behavior-tree node.
  public let nodeID: BehaviorNodeID
  private let emitReport: @Sendable (BehaviorReport) async -> Void

  init(
    nodeID: BehaviorNodeID,
    _ emitReport: @escaping @Sendable (BehaviorReport) async -> Void
  ) {
    self.nodeID = nodeID
    self.emitReport = emitReport
  }

  /// Emits a quantified progress update.
  public func report(
    completed: Int64,
    total: Int64,
    message: String? = nil
  ) async {
    await emitReport(
      .progress(
        BehaviorProgress(completed: completed, total: total, message: message)
      )
    )
  }

  /// Emits normalized progress. The caller is responsible for using `0...1`.
  public func report(fraction: Double, message: String? = nil) async {
    await emitReport(.progress(BehaviorProgress(fraction: fraction, message: message)))
  }

  /// Emits descriptive progress without a numerical unit.
  public func report(message: String) async {
    await emitReport(.progress(BehaviorProgress(message: message)))
  }

  /// Replaces this node's current inspection projection for its activation.
  public func report(inspection: BehaviorInspection) async {
    await emitReport(.inspection(inspection))
  }
}

enum BehaviorReport: Sendable {
  case progress(BehaviorProgress)
  case inspection(BehaviorInspection)
}

actor BehaviorEventSession {
  private let treeName: String
  private let treeVersion: String
  private let executionID: BehaviorExecutionID
  private let definitionByID: [BehaviorNodeID: BehaviorDefinitionNode]
  private let observers: [BehaviorObserver]
  private let startedAt = ContinuousClock.now
  private var sequence: UInt64 = 0
  private var activations: [BehaviorNodeID: UInt64] = [:]

  init(
    definition: BehaviorTreeDefinition,
    executionID: BehaviorExecutionID,
    observers: [BehaviorObserver]
  ) {
    treeName = definition.name
    treeVersion = definition.version
    self.executionID = executionID
    self.observers = observers
    var index: [BehaviorNodeID: BehaviorDefinitionNode] = [:]
    Self.index(definition.root, into: &index)
    definitionByID = index
  }

  func emit(
    _ phase: BehaviorEventPhase,
    nodeID: BehaviorNodeID? = nil,
    attempt: Int? = nil,
    outcome: BehaviorOutcome? = nil,
    diagnostic: BehaviorDiagnostic? = nil,
    progress: BehaviorProgress? = nil,
    inspection: BehaviorInspection? = nil
  ) {
    sequence &+= 1
    if phase == .nodeEntered, let nodeID {
      activations[nodeID, default: 0] &+= 1
    }
    let definition = nodeID.flatMap { definitionByID[$0] }
    let elapsed = BehaviorDuration(startedAt.duration(to: ContinuousClock.now)).nanoseconds
    let event = BehaviorEvent(
      treeName: treeName,
      treeVersion: treeVersion,
      executionID: executionID,
      sequence: sequence,
      nodeID: nodeID,
      activation: nodeID.flatMap { activations[$0] },
      attempt: attempt,
      parentID: definition?.parentID,
      childRole: definition?.role,
      nodeKind: definition?.kind,
      label: definition?.label,
      attributes: definition?.attributes ?? [:],
      phase: phase,
      outcome: outcome,
      diagnostic: diagnostic,
      progress: progress,
      inspection: inspection,
      elapsedNanoseconds: elapsed
    )
    for observer in observers { observer.receive(event) }
  }

  private static func index(
    _ node: BehaviorDefinitionNode,
    into result: inout [BehaviorNodeID: BehaviorDefinitionNode]
  ) {
    result[node.id] = node
    for child in node.children { index(child, into: &result) }
  }
}
