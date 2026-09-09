import Foundation
import Testing

@testable import BehaviorTree

private enum VisualizationAction: String, Sendable {
  case work
}

private enum VisualizationCondition: String, Sendable {
  case unused
}

private actor VisualizationContext {}

private struct VisualizationExecutor: BehaviorExecutor {
  func evaluate(
    _ condition: VisualizationCondition,
    in context: VisualizationContext
  ) throws -> BehaviorConditionResult {
    .unsatisfied
  }

  func perform(
    _ action: VisualizationAction,
    in context: VisualizationContext,
    reporting: BehaviorReporter
  ) async throws -> BehaviorActionResult {
    await reporting.report(fraction: 0.5, message: "half complete")
    await reporting.report(
      inspection: BehaviorInspection(
        summary: "working set ready",
        values: [
          "itemCount": .integer(12),
          "source": .string("primary"),
        ]
      )
    )
    return .succeeded
  }
}

@Test
func treeCreatesCompleteVisualizationFromStringRawValues() throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(
    name: "whole-tree"
  ) {
    Sequence("workflow") {
      Condition(.unused)
      Action(.work)
    }
  }

  let visualization = tree.makeVisualization()

  #expect(visualization.definition.name == "whole-tree")
  #expect(visualization.definition.root.children.count == 2)
  #expect(visualization.definition.root.children[0].label == "unused")
  #expect(visualization.definition.root.children[1].label == "work")
  #expect(visualization.snapshot.nodes.count == 3)
}

@Test
func visualizationSnapshotReducesOrderedNodeState() throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "live") {
    Sequence("root sequence") {
      Action(.work, named: "work")
    }
  }
  let definition = tree.definition(actionName: { $0.rawValue })
  let executionID = BehaviorExecutionID(rawValue: "visualization-test")
  var snapshot = BehaviorVisualizationSnapshot(definition: definition)

  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 1,
      phase: .executionStarted
    )
  )
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 2,
      nodeID: .root,
      activation: 1,
      phase: .nodeEntered
    )
  )
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 3,
      nodeID: BehaviorNodeID(rawValue: "root.0"),
      activation: 1,
      phase: .nodeEntered
    )
  )
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 4,
      nodeID: BehaviorNodeID(rawValue: "root.0"),
      activation: 1,
      phase: .nodeProgress,
      progress: BehaviorProgress(fraction: 0.5, message: "half complete")
    )
  )
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 5,
      nodeID: BehaviorNodeID(rawValue: "root.0"),
      activation: 1,
      phase: .nodeInspected,
      inspection: BehaviorInspection(
        summary: "12 items selected",
        values: [
          "itemCount": .integer(12),
          "source": .string("primary"),
        ]
      )
    )
  )

  #expect(snapshot.status == .running)
  #expect(snapshot.nodes[.root]?.status == .running)
  #expect(snapshot.nodes[BehaviorNodeID(rawValue: "root.0")]?.status == .running)
  #expect(
    snapshot.nodes[BehaviorNodeID(rawValue: "root.0")]?.progress?.fraction == 0.5
  )
  #expect(
    snapshot.nodes[BehaviorNodeID(rawValue: "root.0")]?.inspection?.values["itemCount"]
      == .integer(12)
  )
  #expect(snapshot.latestEvent?.phase == .nodeInspected)

  let graph = try definition.graphviz(highlighting: snapshot)
  let rootLine = graph.split(separator: "\n").first { $0.contains("\"root\" [") }
  let actionLine = graph.split(separator: "\n").first {
    $0.contains("\"root.0\" [label=")
  }
  #expect(rootLine?.contains("penwidth=2") == true)
  #expect(actionLine?.contains("penwidth=3") == true)
  #expect(actionLine?.contains("progress 0.5 · half complete") == true)
  #expect(actionLine?.contains("12 items selected") == true)
  let activeEdge = graph.split(separator: "\n").first {
    $0.contains("\"root\" -> \"root.0\"")
  }
  #expect(activeEdge?.contains("color=\"dodgerblue3\"") == true)
  #expect(activeEdge?.contains("penwidth=3") == true)
  #expect(actionLine?.contains("tooltip=\"") == true)
  #expect(actionLine?.contains("itemCount: 12") == true)
  #expect(actionLine?.contains("source: primary") == true)

  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 6,
      nodeID: BehaviorNodeID(rawValue: "root.0"),
      activation: 1,
      phase: .nodeSucceeded,
      outcome: .succeeded
    )
  )
  #expect(snapshot.nodes[BehaviorNodeID(rawValue: "root.0")]?.status == .succeeded)

  #expect(
    throws: BehaviorVisualizationError.outOfOrderEvent(
      lastSequence: 6,
      receivedSequence: 6
    )
  ) {
    try snapshot.apply(
      visualizationEvent(
        definition: definition,
        executionID: executionID,
        sequence: 6,
        phase: .executionCompleted,
        outcome: .succeeded
      )
    )
  }
}

@Test
func newExecutionStartResetsPreviousNodeState() throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "repeatable") {
    Action(.work)
  }
  let definition = tree.definition()
  let first = BehaviorExecutionID(rawValue: "first")
  let second = BehaviorExecutionID(rawValue: "second")
  var snapshot = BehaviorVisualizationSnapshot(definition: definition)

  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: first,
      sequence: 1,
      nodeID: .root,
      phase: .nodeSucceeded,
      outcome: .succeeded
    )
  )
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: second,
      sequence: 1,
      phase: .executionStarted
    )
  )

  #expect(snapshot.executionID == second)
  #expect(snapshot.status == .running)
  #expect(snapshot.nodes[.root]?.status == .idle)
}

@Test
func inspectionReplacesPriorProjectionAndClearsOnReentry() throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "inspection") {
    Action(.work)
  }
  let definition = tree.definition()
  let executionID = BehaviorExecutionID(rawValue: "inspection")
  var snapshot = BehaviorVisualizationSnapshot(definition: definition)

  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 1,
      nodeID: .root,
      activation: 1,
      phase: .nodeEntered
    )
  )
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 2,
      nodeID: .root,
      activation: 1,
      phase: .nodeInspected,
      inspection: BehaviorInspection(values: ["old": 1])
    )
  )
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 3,
      nodeID: .root,
      activation: 1,
      phase: .nodeInspected,
      inspection: BehaviorInspection(values: ["new": 2])
    )
  )

  #expect(snapshot.nodes[.root]?.inspection?.values == ["new": 2])

  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 4,
      nodeID: .root,
      activation: 2,
      phase: .nodeEntered
    )
  )
  #expect(snapshot.nodes[.root]?.inspection == nil)
}

@Test
func inspectionRoundTripsStructuredDataAndOpaqueAttachments() throws {
  let inspection = BehaviorInspection(
    summary: "Prepared two outputs",
    sections: [
      BehaviorInspectionSection(
        id: "request",
        title: "Request",
        value: .object([
          "items": .array([.string("first"), .string("second")]),
          "enabled": .boolean(true),
          "attempt": .integer(2),
          "score": .double(0.75),
          "missing": .null,
        ])
      )
    ],
    attachments: [
      BehaviorInspectionAttachment(
        id: "host-reference-1",
        label: "Preview",
        role: "output",
        contentType: "image/png",
        byteCount: 512,
        attributes: ["temporary": true]
      )
    ]
  )

  let encoded = try JSONEncoder().encode(inspection)
  let decoded = try JSONDecoder().decode(BehaviorInspection.self, from: encoded)

  #expect(decoded == inspection)
  #expect(decoded.attachments.first?.id == "host-reference-1")
}

@Test
func inspectionEventRequiresPayload() throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "inspection") {
    Action(.work)
  }
  let definition = tree.definition()
  var snapshot = BehaviorVisualizationSnapshot(definition: definition)

  #expect(throws: BehaviorVisualizationError.missingInspection) {
    try snapshot.apply(
      visualizationEvent(
        definition: definition,
        executionID: BehaviorExecutionID(rawValue: "missing-inspection"),
        sequence: 1,
        nodeID: .root,
        phase: .nodeInspected
      )
    )
  }
}

@Test
func parallelVisualizationExposesEveryActiveFrontierNode() throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "parallel") {
    WhenAll {
      Action(.work, named: "first")
      Action(.work, named: "second")
    }
  }
  let definition = tree.definition()
  let executionID = BehaviorExecutionID(rawValue: "parallel")
  var snapshot = BehaviorVisualizationSnapshot(definition: definition)

  for (sequence, nodeID) in [
    (1, BehaviorNodeID.root),
    (2, BehaviorNodeID(rawValue: "root.0")),
    (3, BehaviorNodeID(rawValue: "root.1")),
  ] {
    try snapshot.apply(
      visualizationEvent(
        definition: definition,
        executionID: executionID,
        sequence: UInt64(sequence),
        nodeID: nodeID,
        activation: 1,
        phase: .nodeEntered
      )
    )
  }

  let graph = try definition.graphviz(highlighting: snapshot)
  let lines = graph.split(separator: "\n")
  let rootLine = lines.first { $0.contains("\"root\" [") }
  let firstLine = lines.first { $0.contains("\"root.0\" [") }
  let secondLine = lines.first { $0.contains("\"root.1\" [") }
  #expect(rootLine?.contains("penwidth=2") == true)
  #expect(firstLine?.contains("penwidth=3") == true)
  #expect(secondLine?.contains("penwidth=3") == true)
}

@Test
func visualizationStoreStreamsRuntimeSnapshots() async throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "stream") {
    Action(.work, named: "streamed work")
  }
  let definition = tree.definition(actionName: { $0.rawValue })
  let visualization = BehaviorVisualizationStore(
    definition: definition,
    snapshotBufferCapacity: 32
  )
  let snapshots = visualization.snapshots
  let collector = Task {
    var phases: [BehaviorEventPhase] = []
    for await snapshot in snapshots {
      if let phase = snapshot.latestEvent?.phase { phases.append(phase) }
      if snapshot.status == .succeeded { return phases }
    }
    return phases
  }

  let result = try await tree.run(
    in: VisualizationContext(),
    using: VisualizationExecutor(),
    observing: [visualization.observer]
  )
  let phases = await collector.value

  #expect(result.outcome == .succeeded)
  #expect(phases.contains(.nodeProgress))
  #expect(phases.contains(.nodeInspected))
  #expect(phases.last == .executionCompleted)
  #expect(visualization.snapshot.status == .succeeded)
  #expect(visualization.snapshot.nodes[.root]?.inspection?.summary == "working set ready")
  #expect(visualization.lastError == nil)
  #expect(visualization.graphviz().contains("fillcolor=\"palegreen\""))
}

@Test
func visualizationStoreBroadcastsToIndependentConsumers() async throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(
    name: "broadcast"
  ) {
    Action(.work)
  }
  let definition = tree.definition()
  let visualization = BehaviorVisualizationStore(definition: definition)
  var first = visualization.makeSnapshotStream().makeAsyncIterator()
  var second = visualization.makeSnapshotStream().makeAsyncIterator()

  #expect(await first.next()?.status == .idle)
  #expect(await second.next()?.status == .idle)

  try visualization.record(
    visualizationEvent(
      definition: definition,
      executionID: BehaviorExecutionID(rawValue: "broadcast"),
      sequence: 1,
      phase: .executionStarted
    )
  )

  #expect(await first.next()?.status == .running)
  #expect(await second.next()?.status == .running)
}

@Test
func graphvizThemeAcceptsNamedAndSchemeQualifiedColors() throws {
  let tree = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "themed") {
    Action(.work)
  }
  let definition = tree.definition()
  let executionID = BehaviorExecutionID(rawValue: "themed")
  var snapshot = BehaviorVisualizationSnapshot(definition: definition)
  try snapshot.apply(
    visualizationEvent(
      definition: definition,
      executionID: executionID,
      sequence: 1,
      nodeID: .root,
      phase: .nodeEntered
    )
  )
  var theme = BehaviorGraphvizTheme.default
  theme.backgroundColor = "gray10"
  theme.edgeColor = "gray70"
  theme.edgeTextColor = "gray80"
  theme.fontName = "Menlo"
  theme.running.borderColor = "purple4"
  theme.running.fillColor = "/set312/4"
  theme.running.textColor = "white"
  theme.runningPenWidth = 4
  theme.frontierPenWidth = 6

  let graph = try definition.graphviz(highlighting: snapshot, theme: theme)
  #expect(graph.contains("bgcolor=\"gray10\""))
  #expect(graph.contains("color=\"gray70\""))
  #expect(graph.contains("fontname=\"Menlo\""))
  #expect(graph.contains("color=\"purple4\""))
  #expect(graph.contains("fillcolor=\"/set312/4\""))
  #expect(graph.contains("fontcolor=\"white\""))
  #expect(graph.contains("penwidth=6.0"))
}

@Test
func graphvizRejectsStateFromAnotherDefinition() throws {
  let first = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "first") {
    Action(.work)
  }
  let second = try BehaviorTree<VisualizationAction, VisualizationCondition>(name: "second") {
    Action(.work)
  }
  let snapshot = BehaviorVisualizationSnapshot(definition: first.definition())

  #expect(throws: BehaviorVisualizationError.definitionMismatch) {
    try second.definition().graphviz(highlighting: snapshot)
  }
}

private func visualizationEvent(
  definition: BehaviorTreeDefinition,
  executionID: BehaviorExecutionID,
  sequence: UInt64,
  nodeID: BehaviorNodeID? = nil,
  activation: UInt64? = nil,
  phase: BehaviorEventPhase,
  outcome: BehaviorOutcome? = nil,
  progress: BehaviorProgress? = nil,
  inspection: BehaviorInspection? = nil
) -> BehaviorEvent {
  BehaviorEvent(
    treeName: definition.name,
    treeVersion: definition.version,
    executionID: executionID,
    sequence: sequence,
    nodeID: nodeID,
    activation: activation,
    phase: phase,
    outcome: outcome,
    progress: progress,
    inspection: inspection,
    elapsedNanoseconds: 0
  )
}
