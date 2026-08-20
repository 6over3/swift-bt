@_exported import BehaviorTree
import Synchronization
import Tracing

/// Controls the spans and point-in-time events emitted by the tracing observer.
public struct BehaviorTracingConfiguration: Sendable {
  public var operationPrefix: String
  public var traceNodes: Bool
  public var includeProgressEvents: Bool
  public var includeInspectionEvents: Bool
  public var includeNodeAttributes: Bool

  public init(
    operationPrefix: String = "behavior_tree",
    traceNodes: Bool = true,
    includeProgressEvents: Bool = false,
    includeInspectionEvents: Bool = false,
    includeNodeAttributes: Bool = true
  ) {
    self.operationPrefix = operationPrefix
    self.traceNodes = traceNodes
    self.includeProgressEvents = includeProgressEvents
    self.includeInspectionEvents = includeInspectionEvents
    self.includeNodeAttributes = includeNodeAttributes
  }
}

/// Factories for integrations with Swift Distributed Tracing.
public enum BehaviorTreeTracing {
  /// Creates an observer backed by the globally bootstrapped tracer.
  ///
  /// Capture the request's `ServiceContext` when constructing the observer, or
  /// pass one explicitly when the tree may start in a detached host callback.
  public static func observer(
    context: ServiceContext = .current ?? .topLevel,
    configuration: BehaviorTracingConfiguration = .init()
  ) -> BehaviorObserver {
    let storage = TracingObserverStorage(
      parentContext: context,
      configuration: configuration,
      startSpan: { name, context in
        Tracing.startSpan(name, context: context)
      }
    )
    return BehaviorObserver { event in storage.receive(event) }
  }

  /// Creates an observer backed by an explicitly supplied tracer.
  ///
  /// This overload is useful for tests and applications that avoid global
  /// instrumentation bootstrap.
  public static func observer<TracerType: Tracer>(
    tracer: TracerType,
    context: ServiceContext = .current ?? .topLevel,
    configuration: BehaviorTracingConfiguration = .init()
  ) -> BehaviorObserver {
    let storage = TracingObserverStorage(
      parentContext: context,
      configuration: configuration,
      startSpan: { name, context in
        tracer.startSpan(name, context: context)
      }
    )
    return BehaviorObserver { event in storage.receive(event) }
  }
}

private struct NodeSpanKey: Hashable {
  let executionID: BehaviorExecutionID
  let nodeID: BehaviorNodeID
}

private final class TracingObserverStorage: Sendable {
  private struct State {
    var executionSpans: [BehaviorExecutionID: any Span] = [:]
    var nodeSpans: [NodeSpanKey: any Span] = [:]
  }

  private let parentContext: ServiceContext
  private let configuration: BehaviorTracingConfiguration
  private let start: @Sendable (String, ServiceContext) -> any Span
  private let state = Mutex(State())

  init(
    parentContext: ServiceContext,
    configuration: BehaviorTracingConfiguration,
    startSpan: @escaping @Sendable (String, ServiceContext) -> any Span
  ) {
    self.parentContext = parentContext
    self.configuration = configuration
    start = startSpan
  }

  func receive(_ event: BehaviorEvent) {
    state.withLock { state in
      if event.nodeID == nil {
        receiveExecutionEvent(event, state: &state)
      } else if configuration.traceNodes {
        receiveNodeEvent(event, state: &state)
      }
    }
  }

  private func receiveExecutionEvent(_ event: BehaviorEvent, state: inout State) {
    switch event.phase {
    case .executionStarted:
      guard state.executionSpans[event.executionID] == nil else { return }
      let span = start(
        "\(configuration.operationPrefix).execution",
        parentContext
      )
      applyCommonAttributes(event, to: span)
      state.executionSpans[event.executionID] = span

    case .executionCompleted, .executionFailed, .executionCancelled:
      finishRemainingNodeSpans(for: event.executionID, state: &state)
      guard let span = state.executionSpans.removeValue(forKey: event.executionID) else {
        return
      }
      applyTerminalAttributes(event, to: span)
      switch event.phase {
      case .executionFailed:
        span.setStatus(.init(code: .error, message: event.diagnostic?.summary))
      case .executionCompleted where event.outcome == .failed:
        span.setStatus(.init(code: .error, message: event.diagnostic?.summary))
      case .executionCompleted:
        span.setStatus(.init(code: .ok))
      default:
        break
      }
      span.end()

    default:
      break
    }
  }

  private func receiveNodeEvent(_ event: BehaviorEvent, state: inout State) {
    guard let nodeID = event.nodeID else { return }
    let key = NodeSpanKey(executionID: event.executionID, nodeID: nodeID)
    switch event.phase {
    case .nodeEntered:
      guard state.nodeSpans[key] == nil else { return }
      let context =
        event.parentID.flatMap {
          state.nodeSpans[
            NodeSpanKey(executionID: event.executionID, nodeID: $0)
          ]?.context
        } ?? state.executionSpans[event.executionID]?.context ?? parentContext
      let span = start(
        "\(configuration.operationPrefix).node",
        context
      )
      applyCommonAttributes(event, to: span)
      state.nodeSpans[key] = span

    case .nodeProgress:
      guard configuration.includeProgressEvents, let span = state.nodeSpans[key] else {
        return
      }
      span.addEvent(
        SpanEvent(name: "behavior.node.progress", attributes: progressAttributes(event.progress))
      )

    case .nodeInspected:
      guard configuration.includeInspectionEvents, let span = state.nodeSpans[key] else {
        return
      }
      span.addEvent(
        SpanEvent(
          name: "behavior.node.inspection",
          attributes: inspectionAttributes(event.inspection)
        )
      )

    case .nodeRetrying, .nodeTimedOut:
      state.nodeSpans[key]?.addEvent(
        SpanEvent(
          name: "behavior.node.\(event.phase.rawValue)",
          attributes: diagnosticAttributes(event.diagnostic)
        )
      )

    case .nodeSucceeded, .nodeFailed, .nodeSkipped, .nodeCancelled:
      guard let span = state.nodeSpans.removeValue(forKey: key) else { return }
      applyTerminalAttributes(event, to: span)
      if event.phase == .nodeSucceeded {
        span.setStatus(.init(code: .ok))
      } else if event.diagnostic?.code == "behavior.timeout" {
        span.setStatus(.init(code: .error, message: event.diagnostic?.summary))
      }
      span.end()

    case .nodeReset:
      guard let span = state.nodeSpans.removeValue(forKey: key) else { return }
      span.updateAttributes { $0["behavior.node.reset"] = true }
      span.end()

    default:
      break
    }
  }

  private func finishRemainingNodeSpans(
    for executionID: BehaviorExecutionID,
    state: inout State
  ) {
    let keys = state.nodeSpans.keys.filter { $0.executionID == executionID }
    for key in keys {
      guard let span = state.nodeSpans.removeValue(forKey: key) else { continue }
      span.updateAttributes { $0["behavior.node.incomplete"] = true }
      span.end()
    }
  }

  private func applyCommonAttributes(_ event: BehaviorEvent, to span: any Span) {
    span.updateAttributes { attributes in
      attributes["behavior.tree.name"] = event.treeName
      attributes["behavior.tree.version"] = event.treeVersion
      attributes["behavior.execution.id"] = event.executionID.rawValue
      if let nodeID = event.nodeID {
        attributes["behavior.node.id"] = nodeID.rawValue
      }
      if let activation = event.activation {
        attributes["behavior.node.activation"] = Int64(clamping: activation)
      }
      if let attempt = event.attempt {
        attributes["behavior.retry.attempt"] = attempt
      }
      if let parentID = event.parentID {
        attributes["behavior.node.parent_id"] = parentID.rawValue
      }
      if let kind = event.nodeKind {
        attributes["behavior.node.kind"] = kind.rawValue
      }
      if let label = event.label {
        attributes["behavior.node.label"] = label
      }
      if let role = event.childRole {
        attributes["behavior.node.role"] = roleName(role)
      }
      if configuration.includeNodeAttributes {
        for (key, value) in event.attributes {
          attributes.set("behavior.node.attribute.\(key)", value: spanValue(value))
        }
      }
    }
  }

  private func applyTerminalAttributes(_ event: BehaviorEvent, to span: any Span) {
    span.updateAttributes { attributes in
      attributes["behavior.event.phase"] = event.phase.rawValue
      attributes["behavior.elapsed.nanoseconds"] = event.elapsedNanoseconds
      if let outcome = event.outcome {
        attributes["behavior.outcome"] = outcome.rawValue
      }
      if let diagnostic = event.diagnostic {
        attributes["behavior.diagnostic.code"] = diagnostic.code
        if let summary = diagnostic.summary {
          attributes["behavior.diagnostic.summary"] = summary
        }
        for (key, value) in diagnostic.attributes {
          attributes.set("behavior.diagnostic.\(key)", value: spanValue(value))
        }
      }
    }
  }
}

private func diagnosticAttributes(_ diagnostic: BehaviorDiagnostic?) -> SpanAttributes {
  guard let diagnostic else { return [:] }
  var result: SpanAttributes = ["behavior.diagnostic.code": .string(diagnostic.code)]
  if let summary = diagnostic.summary {
    result["behavior.diagnostic.summary"] = summary
  }
  for (key, value) in diagnostic.attributes {
    result.set("behavior.diagnostic.\(key)", value: spanValue(value))
  }
  return result
}

private func progressAttributes(_ progress: BehaviorProgress?) -> SpanAttributes {
  guard let progress else { return [:] }
  var result: SpanAttributes = [:]
  if let completed = progress.completed { result["completed"] = completed }
  if let total = progress.total { result["total"] = total }
  if let fraction = progress.fraction { result["fraction"] = fraction }
  if let message = progress.message { result["message"] = message }
  return result
}

private func inspectionAttributes(
  _ inspection: BehaviorInspection?
) -> SpanAttributes {
  guard let inspection else { return [:] }
  var result: SpanAttributes = [:]
  if let summary = inspection.summary { result["summary"] = summary }
  for (key, value) in inspection.values {
    result.set(key, value: spanValue(value))
  }
  return result
}

private func spanValue(_ value: BehaviorMetadataValue) -> SpanAttribute {
  switch value {
  case .boolean(let value): .bool(value)
  case .integer(let value): .int64(value)
  case .double(let value): .double(value)
  case .string(let value): .string(value)
  }
}

private func roleName(_ role: BehaviorChildRole) -> String {
  switch role {
  case .root: "root"
  case .child(let index): "child:\(index)"
  case .condition: "condition"
  case .thenBranch: "then"
  case .elseBranch: "else"
  case .body(let index): "body:\(index)"
  case .wrapped: "wrapped"
  case .onSuccess: "on_success"
  case .onFailure: "on_failure"
  case .onCancel: "on_cancel"
  case .onExit: "on_exit"
  }
}
