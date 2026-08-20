@_exported import BehaviorTree
import Metrics
import Synchronization

/// Controls metric names, dimensions, and event volume.
public struct BehaviorMetricsConfiguration: Sendable {
  public var labelPrefix: String
  public var dimensions: [(String, String)]
  public var includeNodeEvents: Bool
  public var includeProgressEvents: Bool
  public var includeInspectionEvents: Bool

  public init(
    labelPrefix: String = "swift_bt",
    dimensions: [(String, String)] = [],
    includeNodeEvents: Bool = true,
    includeProgressEvents: Bool = false,
    includeInspectionEvents: Bool = false
  ) {
    self.labelPrefix = labelPrefix
    self.dimensions = dimensions
    self.includeNodeEvents = includeNodeEvents
    self.includeProgressEvents = includeProgressEvents
    self.includeInspectionEvents = includeInspectionEvents
  }
}

/// Factories for behavior-tree integrations with Swift Metrics.
public enum BehaviorTreeMetrics {
  /// Creates a cached, thread-safe metrics observer.
  ///
  /// Execution IDs, node IDs, labels, and diagnostic codes are intentionally
  /// excluded from dimensions to avoid unbounded metric cardinality.
  public static func observer(
    configuration: BehaviorMetricsConfiguration = .init(),
    factory: any MetricsFactory = MetricsSystem.factory
  ) -> BehaviorObserver {
    let storage = MetricsObserverStorage(
      configuration: configuration,
      factory: factory
    )
    return BehaviorObserver { event in storage.receive(event) }
  }
}

private struct MetricKey: Hashable {
  let label: String
  let dimensions: [MetricDimension]
}

private struct MetricDimension: Hashable {
  let name: String
  let value: String
}

private struct NodeExecutionKey: Hashable {
  let executionID: BehaviorExecutionID
  let nodeID: BehaviorNodeID
}

private final class MetricsObserverStorage: Sendable {
  private struct State {
    var counters: [MetricKey: Counter] = [:]
    var timers: [MetricKey: Timer] = [:]
    var nodeEnteredAt: [NodeExecutionKey: Int64] = [:]
  }

  private let configuration: BehaviorMetricsConfiguration
  private let factory: any MetricsFactory
  private let state = Mutex(State())

  init(
    configuration: BehaviorMetricsConfiguration,
    factory: any MetricsFactory
  ) {
    self.configuration = configuration
    self.factory = factory
  }

  func receive(_ event: BehaviorEvent) {
    state.withLock { state in
      if event.nodeID == nil {
        recordExecutionEvent(event, state: &state)
      } else if configuration.includeNodeEvents {
        recordNodeEvent(event, state: &state)
      }
    }
  }

  private func recordExecutionEvent(_ event: BehaviorEvent, state: inout State) {
    let dimensions =
      executionDimensions(for: event)
      + [MetricDimension(name: "phase", value: event.phase.rawValue)]
      + outcomeDimension(for: event)
    counter(label: "events_total", dimensions: dimensions, state: &state).increment()

    switch event.phase {
    case .executionCompleted, .executionFailed, .executionCancelled:
      timer(
        label: "execution_duration",
        dimensions: executionDimensions(for: event) + outcomeDimension(for: event),
        state: &state
      ).recordNanoseconds(max(0, event.elapsedNanoseconds))
      state.nodeEnteredAt = state.nodeEnteredAt.filter {
        $0.key.executionID != event.executionID
      }
    default:
      break
    }
  }

  private func recordNodeEvent(_ event: BehaviorEvent, state: inout State) {
    guard let nodeID = event.nodeID else { return }
    if event.phase == .nodeProgress, !configuration.includeProgressEvents {
      return
    }
    if event.phase == .nodeInspected, !configuration.includeInspectionEvents {
      return
    }
    let key = NodeExecutionKey(executionID: event.executionID, nodeID: nodeID)
    if event.phase == .nodeEntered {
      state.nodeEnteredAt[key] = event.elapsedNanoseconds
    }

    let dimensions =
      nodeDimensions(for: event)
      + [MetricDimension(name: "phase", value: event.phase.rawValue)]
      + outcomeDimension(for: event)
    counter(label: "node_events_total", dimensions: dimensions, state: &state)
      .increment()

    switch event.phase {
    case .nodeSucceeded, .nodeFailed, .nodeSkipped, .nodeCancelled:
      if let enteredAt = state.nodeEnteredAt.removeValue(forKey: key) {
        timer(
          label: "node_duration",
          dimensions: nodeDimensions(for: event) + outcomeDimension(for: event),
          state: &state
        ).recordNanoseconds(max(0, event.elapsedNanoseconds - enteredAt))
      }
    case .nodeReset:
      state.nodeEnteredAt.removeValue(forKey: key)
    default:
      break
    }
  }

  private func executionDimensions(for event: BehaviorEvent) -> [MetricDimension] {
    configuration.dimensions.map(MetricDimension.init)
      + [
        MetricDimension(name: "tree", value: event.treeName),
        MetricDimension(name: "tree_version", value: event.treeVersion),
      ]
  }

  private func nodeDimensions(for event: BehaviorEvent) -> [MetricDimension] {
    var result = executionDimensions(for: event)
    if let kind = event.nodeKind {
      result.append(MetricDimension(name: "node_kind", value: kind.rawValue))
    }
    return result
  }

  private func outcomeDimension(for event: BehaviorEvent) -> [MetricDimension] {
    event.outcome.map { [MetricDimension(name: "outcome", value: $0.rawValue)] } ?? []
  }

  private func counter(
    label: String,
    dimensions: [MetricDimension],
    state: inout State
  ) -> Counter {
    let key = MetricKey(label: label, dimensions: dimensions)
    if let counter = state.counters[key] { return counter }
    let counter = Counter(
      label: "\(configuration.labelPrefix)_\(label)",
      dimensions: dimensions.map { ($0.name, $0.value) },
      factory: factory
    )
    state.counters[key] = counter
    return counter
  }

  private func timer(
    label: String,
    dimensions: [MetricDimension],
    state: inout State
  ) -> Timer {
    let key = MetricKey(label: label, dimensions: dimensions)
    if let timer = state.timers[key] { return timer }
    let timer = Timer(
      label: "\(configuration.labelPrefix)_\(label)",
      dimensions: dimensions.map { ($0.name, $0.value) },
      factory: factory
    )
    state.timers[key] = timer
    return timer
  }
}

extension MetricDimension {
  fileprivate init(_ pair: (String, String)) {
    self.init(name: pair.0, value: pair.1)
  }
}
