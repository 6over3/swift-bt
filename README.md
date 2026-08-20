# swift-bt

[![CI](https://github.com/6over3/swift-bt/actions/workflows/ci.yml/badge.svg)](https://github.com/6over3/swift-bt/actions/workflows/ci.yml)

A strongly typed Swift implementation of behavior trees with structured
concurrency, host-driven execution, diagnostics, telemetry, and visualization.

A behavior tree is an executable decision graph. Sequences express ordered
requirements, selectors express prioritized fallback, decorators add policies
such as retry and timeout, and parallel nodes coordinate concurrent work. The
same model applies to service orchestration, autonomous systems, schedulers,
embedded controllers, simulations, and game AI.

swift-bt owns control flow and transient execution state. Your application
continues to own its domain data, persistence, transactions, and side effects.

```swift
import BehaviorTree

enum Operation: String, Codable, Sendable {
  case readCache
  case queryPrimary
  case queryReplicaA
  case queryReplicaB
  case returnFallback
}

enum Predicate: String, Codable, Sendable {
  case cacheContainsKey
  case primaryAvailable
}

let lookup = try BehaviorTree<Operation, Predicate>(name: "resilient-lookup") {
  Selector("resolve value", memory: .reactive) {
    Sequence("cache") {
      Condition(.cacheContainsKey)
      Action(.readCache)
    }

    Sequence("primary") {
      Condition(.primaryAvailable)

      Retry(maximumAttempts: 3, backoff: .milliseconds(100)) {
        Timeout(.seconds(2)) {
          Action(.queryPrimary)
        }
      }
    }

    WhenAny("replicas") {
      Timeout(.seconds(2)) { Action(.queryReplicaA) }
      Timeout(.seconds(2)) { Action(.queryReplicaB) }
    }

    Action(.returnFallback)
  }
}
```

This tree tries the cheapest path first, retries a bounded primary request,
queries replicas concurrently, and finally produces a fallback. The structure
makes ordering, failure policy, and concurrency visible without embedding them
in nested closures or ad hoc state flags.

The builder requires one explicit root, so control flow never depends on an
implicit top-level sequence.

## Installation

```swift
dependencies: [
  .package(url: "https://github.com/6over3/swift-bt", from: "0.1.0")
]
```

Add the `BehaviorTree` product to your target. Optional products provide a
native SwiftUI visualizer, SwiftLog, Swift Metrics, and Swift Distributed
Tracing integrations.

swift-bt requires Swift 6 and macOS 15, iOS/tvOS 18, watchOS 11, or visionOS 2.

To launch the included live visualizer sample on macOS:

```sh
swift run BehaviorTreeSample
```

It auto-runs a workflow that reports progress and retries once. Disable
**Primary available** before pressing **Run** to watch the selector fall back to
two concurrent replica branches and cancel the slower branch.

## Connect the leaves

Actions and conditions are application-defined, strongly typed values. One
`BehaviorExecutor` maps them to your system in every driving style. Its context
is `Sendable`, so shared mutable state can live safely in an actor.

```swift
actor LookupContext {
  // Cache, clients, request state, and result storage belong here.
}

struct LookupExecutor: BehaviorExecutor {
  func evaluate(
    _ predicate: Predicate,
    in context: LookupContext
  ) async throws -> BehaviorConditionResult {
    switch predicate {
    case .cacheContainsKey:
      return await cacheContainsKey(in: context)
        ? .satisfied
        : .unsatisfied(code: "lookup.cache-miss")

    case .primaryAvailable:
      return await primaryIsAvailable(in: context)
        ? .satisfied
        : .unsatisfied(code: "lookup.primary-unavailable")
    }
  }

  func perform(
    _ operation: Operation,
    in context: LookupContext,
    reporting: BehaviorReporter
  ) async throws -> BehaviorActionResult {
    switch operation {
    case .readCache:
      return await readCache(into: context)
    case .queryPrimary:
      return try await queryPrimary(into: context, reporting: reporting)
    case .queryReplicaA:
      return try await queryReplicaA(into: context, reporting: reporting)
    case .queryReplicaB:
      return try await queryReplicaB(into: context, reporting: reporting)
    case .returnFallback:
      return await useFallback(in: context)
    }
  }
}
```

The protocol requirements are asynchronous, but Swift permits an ordinary
synchronous method to satisfy them. Quick local operations and suspending I/O
therefore use the same executor API. `async` does not implicitly move CPU-heavy
work to another thread.

Conditions return `BehaviorConditionResult`, not a bare `Bool`, so an
unsatisfied decision can carry a stable, machine-readable explanation:

```swift
return .unsatisfied(
  code: "lookup.replica-lagging",
  summary: "Replica is behind the required revision",
  attributes: [
    "requiredRevision": 812,
    "observedRevision": 799,
  ]
)
```

Expected failure is behavior-tree control flow. A thrown Swift error aborts the
execution and is wrapped with the ID of the node that threw it.

### Share results and expose inspection data

Leaves exchange typed application values through the executor's `Context`.
The library does not impose an untyped blackboard or require values to conform
to `Codable`. Use an immutable `Sendable` value for read-only inputs, or an
actor when leaves and concurrent branches share mutable results:

```swift
actor LookupContext {
  private(set) var selectedRecord: Record?

  func select(_ record: Record) {
    selectedRecord = record
  }
}
```

That state is opaque to the behavior tree. An action can deliberately publish
a small `BehaviorInspection` when an operator or visualization should see part
of it:

```swift
await reporting.report(
  inspection: BehaviorInspection(
    summary: "Primary record selected",
    values: [
      "recordID": .string(record.id),
      "revision": .integer(Int64(record.revision)),
      "cached": .boolean(record.isCached),
    ]
  )
)
```

The latest inspection replaces the previous inspection for that node
activation and is cleared when the node starts again. It travels as a
`nodeInspected` event, appears in visualization snapshots, the SwiftUI node
inspector, and Graphviz SVG tooltips, and can be forwarded to logs or traces.
Only publish bounded, non-sensitive scalar values; inspection is observability,
not workflow storage or an input to another leaf.

## Drive the tree

Run the tree continuously and await its terminal result:

```swift
let result = try await lookup.run(
  in: lookupContext,
  using: LookupExecutor()
)
```

Parallel nodes use Swift structured concurrency. Cancellation propagates to
child tasks, losing race branches are cancelled and awaited, and waits,
timeouts, and retry backoff use an injectable `BehaviorClock`.

When an event loop, scheduler, controller, or simulation owns progression,
advance the same tree explicitly:

```swift
var execution = lookup.makeExecution()

let status = try await execution.advance(
  in: lookupContext,
  using: LookupExecutor(),
  elapsed: timeSinceLastEvent
)
```

If a leaf suspends, `advance` suspends without blocking a thread. Built-in
waits, loops, reactive branches, and parallel nodes can remain `.running`
between advances. The execution preserves their cursors and passes unused
elapsed time to the next sequential child.

Host-driven execution state is data-only and can be restored between advances:

```swift
let data = try JSONEncoder().encode(execution.snapshot())
let snapshot = try JSONDecoder().decode(
  BehaviorExecutionSnapshot.self,
  from: data
)
var restored = try lookup.makeExecution(restoring: snapshot)
```

The snapshot represents behavior-tree state only. Persisting it, coordinating
leases, and making side effects idempotent remain responsibilities of the host.

Reactive selectors and sequences reconsider priority on every host advance. A
continuously driven tree uses explicit invalidation instead of polling:

```swift
let task = lookup.start(in: lookupContext, using: LookupExecutor())

// A cache fill, health transition, configuration change, or other event can
// invalidate the current choice.
await task.invalidate()

let result = try await task.value
```

## Nodes

- `Sequence`, `Selector`, and `If`
- `WhenAll`, `WhenAny`, `Race`, threshold-based `Parallel`, and `OrderedSuccess`
- `While`, `WhileAll`, `Retry`, `Repeat`, and `UntilFailure`
- `Invert`, `ForceSuccess`, `ForceFailure`, `Timeout`, and `Precondition`
- `Lifecycle` with typed success, failure, cancellation, and exit hooks
- `Subtree` for named, reusable tree composition
- `Wait`, `WaitForever`, `Succeed`, and `Fail`

`Sequence` and `Selector` remember their active child by default. Set
`memory: .reactive` when higher-priority branches should be reconsidered after
the surrounding system changes.

## Reusable subtrees

Build a tree once and embed it anywhere the parent uses the same action and
condition types:

```swift
let primaryLookup = try BehaviorTree<Operation, Predicate>(
  name: "primary-lookup",
  version: "2"
) {
  Sequence {
    Condition(.primaryAvailable)
    Action(.queryPrimary)
  }
}

let resilientLookup = try BehaviorTree<Operation, Predicate>(name: "resilient-lookup") {
  Selector {
    Subtree(primaryLookup)
    Action(.returnFallback)
  }
}
```

`Subtree` is transparent to execution but remains a named node in definitions,
events, snapshots, and visualizations. Reusing one subtree in several places
gives each embedding parent-scoped node IDs and independent runtime state. The
host still owns the shared context and any values produced by earlier actions.

## Visualization and telemetry

### Native SwiftUI view

Add the optional `BehaviorTreeUI` product to embed a live visualizer directly
in an app:

```swift
import BehaviorTreeUI

let visualization = lookup.makeVisualization()

BehaviorTreeView(visualization: visualization)
  .frame(minHeight: 420)
  .behaviorTreePanEnabled(true)
  .behaviorTreeZoomEnabled(true)
  .behaviorTreeControlsVisible(true)
  .behaviorTreeLegendVisible(true)
```

`lookup` is the complete tree. `makeVisualization()` derives its full topology;
the sample action and condition enums use string raw values as display labels.
For other domain types, pass `actionLabel:` and `conditionLabel:` closures.

Pass `visualization.observer` when starting or manually advancing the tree. The
view updates from semantic execution events rather than assuming a tick loop,
and displays running frontiers, terminal paths, retries, progress, diagnostics,
inspections, skips, cancellation, execution status, and event sequence. Tap a
node for its full label and current details. Add `.inspection` to
`behaviorTreeNodeDetails` to place its summary directly on node cards.

The renderer uses one asynchronously rendered SwiftUI `Canvas`. Tree layout is
computed once, off the main actor, while viewport culling avoids resolving text
or drawing geometry outside the visible region. For definitions reused across
several views, precompute the immutable layout explicitly:

```swift
let layout = BehaviorTreeDiagramLayout(
  direction: .leftToRight
)
let diagram = BehaviorTreeDiagram(
  definition: visualization.definition,
  layout: layout
)

BehaviorTreeView(diagram: diagram, visualization: visualization)
  .behaviorTreeInspectorEnabled(false)
  .behaviorTreeNodeDetails([.status, .progress])
  .behaviorTreeZoomRange(minimum: 0.5, maximum: 4)
```

Pan, zoom, controls, the legend, execution status, inspector, displayed detail,
theme, and asynchronous rendering are independently configurable with view
modifiers. Layouts can run top-down or left-to-right. Runtime events animate the
affected node and progress rail without requiring a permanent display loop; the
view respects Reduce Motion.

### Definitions, Graphviz, and external renderers

`definition()` returns a data-only, `Codable` graph with stable node IDs, parent
relationships, child roles, labels, kinds, and attributes. It can produce
static Graphviz DOT directly:

```swift
let definition = lookup.definition(
  actionName: { $0.rawValue },
  conditionName: { $0.rawValue }
)

let graphvizDOT = definition.graphviz()
```

For real-time visualization, attach a `BehaviorVisualizationStore` as an
observer. It reduces every event synchronously, while its bounded stream emits
complete snapshots for a renderer, websocket, debugger, or recording system:

```swift
let visualization = BehaviorVisualizationStore(definition: definition)
let task = lookup.start(
  in: lookupContext,
  using: LookupExecutor(),
  observing: [visualization.observer]
)

for await snapshot in visualization.snapshots {
  let dot = try definition.graphviz(highlighting: snapshot)
  await sendToVisualizer(dot)

  if snapshot.status != .idle && snapshot.status != .running {
    break
  }
}

let result = try await task.value
```

The snapshot contains the state of every node, including activation, retry
attempt, progress, inspection, diagnostics, and the latest event. Dynamic
Graphviz output colors terminal nodes and their path edges, highlights running
ancestors, gives the active frontier a heavier outline, and includes inspection
values in full hover tooltips in SVG output. Parallel branches may expose
several frontier nodes at once.

The snapshot stream keeps the newest values when its consumer falls behind.
Each value is complete, so dropped intermediate frames do not make the latest
render incomplete. A custom renderer can consume `snapshot.nodes` directly and
keep its layout fixed instead of asking Graphviz to lay out every frame.

Graphviz output is themed rather than tied to fixed colors. The default uses
portable named colors, and callers can replace the canvas, edges, font, every
node state, and active border widths:

```swift
var theme = BehaviorGraphvizTheme.default
theme.backgroundColor = "gray10"
theme.edgeColor = "gray70"
theme.edgeTextColor = "gray80"
theme.fontName = "Menlo"
theme.running.borderColor = "purple4"
theme.running.fillColor = "/set312/4"
theme.running.textColor = "white"
theme.succeeded.fillColor = "palegreen"

let dot = try definition.graphviz(
  highlighting: visualization.snapshot,
  theme: theme
)
```

Theme colors accept Graphviz names, scheme-qualified names, and custom color
values. See the [Graphviz color documentation](https://graphviz.org/doc/info/colors.html).

Observe semantic execution events directly or use an adapter:

```swift
let observer = BehaviorObserver { event in
  print(event.sequence, event.nodeID?.description ?? "execution", event.phase)
}

let result = try await lookup.run(
  in: lookupContext,
  using: LookupExecutor(),
  observing: [observer]
)
```

```swift
import BehaviorTreeLogging
import BehaviorTreeMetrics
import BehaviorTreeTracing

let observers: [BehaviorObserver] = [
  BehaviorTreeLogging.observer(logger: logger),
  BehaviorTreeMetrics.observer(),
  BehaviorTreeTracing.observer(),
]
```

Events include node activation, retry attempt, progress, inspection, outcome,
diagnostic, and elapsed time. Logging includes deliberately reported inspection
values. Tracing and metrics exclude inspection events by default; enable
`includeInspectionEvents` in their configurations when wanted. The metrics
adapter never uses inspection values as dimensions and excludes other
unbounded dimensions such as execution IDs and node labels.
