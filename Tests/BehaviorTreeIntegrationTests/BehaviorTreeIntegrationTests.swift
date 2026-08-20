import BehaviorTreeLogging
import BehaviorTreeMetrics
import BehaviorTreeTracing
import InMemoryTracing
import Logging
import MetricsTestKit
import Synchronization
import Testing

private enum IntegrationAction: Sendable {
  case ingest
}

private enum IntegrationCondition: Sendable {
  case ready
}

private struct IntegrationExecutor: BehaviorExecutor {
  struct Context: Sendable {}

  func evaluate(
    _ condition: IntegrationCondition,
    in context: Context
  ) throws -> BehaviorConditionResult {
    .satisfied
  }

  func perform(
    _ action: IntegrationAction,
    in context: Context,
    reporting: BehaviorReporter
  ) async throws -> BehaviorActionResult {
    await reporting.report(
      inspection: BehaviorInspection(
        summary: "file classified",
        values: [
          "contentType": .string("application/pdf"),
          "pageCount": .integer(8),
        ]
      )
    )
    return .succeeded
  }
}

private final class LogStorage: Sendable {
  private let storage = Mutex<[LogEvent]>([])

  var events: [LogEvent] { storage.withLock { $0 } }

  func append(_ event: LogEvent) {
    storage.withLock { $0.append(event) }
  }
}

private struct CapturingLogHandler: LogHandler {
  var metadataProvider: Logger.MetadataProvider?
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .trace
  let storage: LogStorage

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    storage.append(event)
  }
}

private func integrationTree() throws -> BehaviorTree<IntegrationAction, IntegrationCondition> {
  try BehaviorTree(name: "integration", version: "3") {
    Sequence("ingestion") {
      Action(
        .ingest,
        named: "ingest file",
        attributes: ["queue": .string("default")]
      )
    }
  }
}

@Test
func loggingObserverEmitsStructuredNodeMetadata() async throws {
  let storage = LogStorage()
  let logger = Logger(label: "test") { _ in
    CapturingLogHandler(storage: storage)
  }
  let observer = BehaviorTreeLogging.observer(logger: logger)

  var execution = try integrationTree().makeExecution(observing: [observer])
  let context = IntegrationExecutor.Context()
  let executor = IntegrationExecutor()
  #expect(try await execution.advance(in: context, using: executor) == .succeeded)

  let action = storage.events.first {
    $0.metadata?["behavior.node.label"]?.description == "ingest file"
  }
  #expect(action != nil)
  #expect(
    action?.metadata?["behavior.node.attribute.queue"]?.description == "default"
  )
  let inspection = storage.events.first {
    $0.metadata?["behavior.event.phase"]?.description == "nodeInspected"
  }
  #expect(
    inspection?.metadata?["behavior.inspection.summary"]?.description
      == "file classified"
  )
  #expect(
    inspection?.metadata?["behavior.inspection.pageCount"]?.description == "8"
  )
}

@Test
func metricsObserverUsesBoundedDimensionsAndRecordsDurations() async throws {
  let metrics = TestMetrics()
  let observer = BehaviorTreeMetrics.observer(factory: metrics)

  var execution = try integrationTree().makeExecution(observing: [observer])
  let context = IntegrationExecutor.Context()
  let executor = IntegrationExecutor()
  #expect(try await execution.advance(in: context, using: executor) == .succeeded)

  #expect(metrics.counters.contains { $0.label == "swift_bt_events_total" })
  #expect(metrics.timers.contains { $0.label == "swift_bt_execution_duration" })
  #expect(
    metrics.counters.allSatisfy { counter in
      counter.dimensions.allSatisfy { $0.0 != "execution_id" && $0.0 != "node_id" }
    }
  )
  #expect(
    !metrics.counters.contains { counter in
      counter.dimensions.contains { $0 == ("phase", "nodeInspected") }
    }
  )
}

@Test
func metricsObserverCanCountInspectionEventsWithoutUsingTheirValues() async throws {
  let metrics = TestMetrics()
  let observer = BehaviorTreeMetrics.observer(
    configuration: BehaviorMetricsConfiguration(includeInspectionEvents: true),
    factory: metrics
  )

  var execution = try integrationTree().makeExecution(observing: [observer])
  #expect(
    try await execution.advance(
      in: IntegrationExecutor.Context(),
      using: IntegrationExecutor()
    ) == .succeeded
  )

  let inspectionCounter = metrics.counters.first { counter in
    counter.dimensions.contains { $0 == ("phase", "nodeInspected") }
  }
  #expect(inspectionCounter?.totalValue == 1)
  #expect(
    inspectionCounter?.dimensions.allSatisfy {
      $0.0 != "contentType" && $0.0 != "pageCount"
    } == true
  )
}

@Test
func tracingObserverCreatesParentedExecutionAndNodeSpans() async throws {
  let tracer = InMemoryTracer()
  let observer = BehaviorTreeTracing.observer(tracer: tracer, context: .topLevel)
  let recordedEvents = Mutex<[BehaviorEvent]>([])
  let recorder = BehaviorObserver { event in
    recordedEvents.withLock { $0.append(event) }
  }

  var execution = try integrationTree().makeExecution(observing: [observer, recorder])
  let context = IntegrationExecutor.Context()
  let executor = IntegrationExecutor()
  #expect(try await execution.advance(in: context, using: executor) == .succeeded)
  #expect(recordedEvents.withLock { $0.last?.phase } == .executionCompleted)
  #expect(tracer.activeSpans.isEmpty)

  let spans = tracer.finishedSpans
  #expect(spans.count == 3)
  let executionSpan = spans.first { $0.operationName == "behavior_tree.execution" }
  let nodeSpans = spans.filter { $0.operationName == "behavior_tree.node" }
  #expect(executionSpan != nil)
  #expect(nodeSpans.count == 2)
  #expect(nodeSpans.flatMap(\.events).allSatisfy { $0.name != "behavior.node.inspection" })
  #expect(nodeSpans.contains { $0.parentSpanID == executionSpan?.spanID })
  #expect(
    nodeSpans.contains { node in
      nodeSpans.contains { $0.parentSpanID == node.spanID }
    })
}

@Test
func tracingObserverCanAttachInspectionEventsToNodeSpans() async throws {
  let tracer = InMemoryTracer()
  let observer = BehaviorTreeTracing.observer(
    tracer: tracer,
    context: .topLevel,
    configuration: BehaviorTracingConfiguration(includeInspectionEvents: true)
  )
  var execution = try integrationTree().makeExecution(observing: [observer])

  #expect(
    try await execution.advance(
      in: IntegrationExecutor.Context(),
      using: IntegrationExecutor()
    ) == .succeeded
  )

  let inspection = tracer.finishedSpans
    .flatMap(\.events)
    .first { $0.name == "behavior.node.inspection" }
  #expect(inspection != nil)
  #expect(inspection?.attributes.get("summary") == .string("file classified"))
  #expect(inspection?.attributes.get("pageCount") == .int64(8))
}

@Test
func tracingObserverCanRecordOnlyTheExecutionSpan() async throws {
  let tracer = InMemoryTracer()
  let events = Mutex<[BehaviorEvent]>([])
  let observer = BehaviorTreeTracing.observer(
    tracer: tracer,
    context: .topLevel,
    configuration: BehaviorTracingConfiguration(traceNodes: false)
  )
  var execution = try integrationTree().makeExecution(
    observing: [
      observer,
      BehaviorObserver { event in events.withLock { $0.append(event) } },
    ]
  )
  let context = IntegrationExecutor.Context()
  let executor = IntegrationExecutor()

  #expect(try await execution.advance(in: context, using: executor) == .succeeded)
  #expect(
    events.withLock { $0.filter { $0.nodeID == nil }.map(\.phase) }
      == [.executionStarted, .executionCompleted]
  )
  #expect(tracer.finishedSpans.map(\.operationName) == ["behavior_tree.execution"])
  #expect(tracer.activeSpans.isEmpty)
}
