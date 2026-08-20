@_exported import BehaviorTree
import Logging

/// Controls the severity and detail emitted by the SwiftLog observer.
public struct BehaviorLoggingConfiguration: Sendable {
  public var executionLevel: Logger.Level
  public var nodeLevel: Logger.Level
  public var progressLevel: Logger.Level
  public var inspectionLevel: Logger.Level
  public var failureLevel: Logger.Level
  public var includeNodeAttributes: Bool

  public init(
    executionLevel: Logger.Level = .info,
    nodeLevel: Logger.Level = .debug,
    progressLevel: Logger.Level = .trace,
    inspectionLevel: Logger.Level = .debug,
    failureLevel: Logger.Level = .notice,
    includeNodeAttributes: Bool = true
  ) {
    self.executionLevel = executionLevel
    self.nodeLevel = nodeLevel
    self.progressLevel = progressLevel
    self.inspectionLevel = inspectionLevel
    self.failureLevel = failureLevel
    self.includeNodeAttributes = includeNodeAttributes
  }
}

/// Factories for behavior-tree integrations with SwiftLog.
public enum BehaviorTreeLogging {
  /// Creates an observer that writes one structured log entry per semantic event.
  public static func observer(
    logger: Logger,
    configuration: BehaviorLoggingConfiguration = .init()
  ) -> BehaviorObserver {
    BehaviorObserver { event in
      logger.log(
        level: level(for: event.phase, configuration: configuration),
        "behavior tree \(event.phase.rawValue)",
        metadata: metadata(for: event, configuration: configuration),
        source: "swift-bt"
      )
    }
  }
}

private func level(
  for phase: BehaviorEventPhase,
  configuration: BehaviorLoggingConfiguration
) -> Logger.Level {
  switch phase {
  case .executionStarted, .executionCompleted, .executionCancelled:
    configuration.executionLevel
  case .executionFailed, .nodeTimedOut:
    configuration.failureLevel
  case .nodeFailed:
    configuration.failureLevel
  case .nodeProgress:
    configuration.progressLevel
  case .nodeInspected:
    configuration.inspectionLevel
  default:
    configuration.nodeLevel
  }
}

private func metadata(
  for event: BehaviorEvent,
  configuration: BehaviorLoggingConfiguration
) -> Logger.Metadata {
  var result: Logger.Metadata = [
    "behavior.tree.name": .string(event.treeName),
    "behavior.tree.version": .string(event.treeVersion),
    "behavior.execution.id": .string(event.executionID.rawValue),
    "behavior.event.sequence": .stringConvertible(event.sequence),
    "behavior.event.phase": .string(event.phase.rawValue),
    "behavior.elapsed.nanoseconds": .stringConvertible(event.elapsedNanoseconds),
  ]
  if let nodeID = event.nodeID {
    result["behavior.node.id"] = .string(nodeID.rawValue)
  }
  if let activation = event.activation {
    result["behavior.node.activation"] = .stringConvertible(activation)
  }
  if let attempt = event.attempt {
    result["behavior.retry.attempt"] = .stringConvertible(attempt)
  }
  if let parentID = event.parentID {
    result["behavior.node.parent_id"] = .string(parentID.rawValue)
  }
  if let kind = event.nodeKind {
    result["behavior.node.kind"] = .string(kind.rawValue)
  }
  if let label = event.label {
    result["behavior.node.label"] = .string(label)
  }
  if let outcome = event.outcome {
    result["behavior.outcome"] = .string(outcome.rawValue)
  }
  if let diagnostic = event.diagnostic {
    result["behavior.diagnostic.code"] = .string(diagnostic.code)
    if let summary = diagnostic.summary {
      result["behavior.diagnostic.summary"] = .string(summary)
    }
    for (key, value) in diagnostic.attributes {
      result["behavior.diagnostic.\(key)"] = logValue(value)
    }
  }
  if let progress = event.progress {
    if let completed = progress.completed {
      result["behavior.progress.completed"] = .stringConvertible(completed)
    }
    if let total = progress.total {
      result["behavior.progress.total"] = .stringConvertible(total)
    }
    if let fraction = progress.fraction {
      result["behavior.progress.fraction"] = .stringConvertible(fraction)
    }
    if let message = progress.message {
      result["behavior.progress.message"] = .string(message)
    }
  }
  if let inspection = event.inspection {
    if let summary = inspection.summary {
      result["behavior.inspection.summary"] = .string(summary)
    }
    for (key, value) in inspection.values {
      result["behavior.inspection.\(key)"] = logValue(value)
    }
  }
  if configuration.includeNodeAttributes {
    for (key, value) in event.attributes {
      result["behavior.node.attribute.\(key)"] = logValue(value)
    }
  }
  return result
}

private func logValue(_ value: BehaviorMetadataValue) -> Logger.MetadataValue {
  switch value {
  case .boolean(let value): .stringConvertible(value)
  case .integer(let value): .stringConvertible(value)
  case .double(let value): .stringConvertible(value)
  case .string(let value): .string(value)
  }
}
