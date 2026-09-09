import BehaviorTree
import SwiftUI

#if os(macOS)
  import AppKit
#elseif os(iOS) || os(visionOS)
  import UIKit
#endif

/// An embeddable, real-time SwiftUI visualization of a behavior tree.
///
/// The view renders with one viewport-culling ``Canvas``. Definition layout is
/// computed once and reused while execution snapshots update node and edge
/// state. Use the live initializer with ``BehaviorVisualizationStore`` for a
/// self-updating view, or pass snapshots from another data source.
public struct BehaviorTreeView: View {
  @Environment(\.behaviorTreeViewConfiguration) private var configuration
  @Environment(\.behaviorTreeViewTheme) private var theme
  @State private var generatedDiagram: BehaviorTreeDiagram?
  @State private var diagramFailure: BehaviorTreeDiagramError?
  @State private var liveSnapshot: BehaviorVisualizationSnapshot?
  @State private var internalSelection: BehaviorNodeID?

  private let definition: BehaviorTreeDefinition
  private let preparedDiagram: BehaviorTreeDiagram?
  private let snapshot: BehaviorVisualizationSnapshot?
  private let visualization: BehaviorVisualizationStore?
  private let layout: BehaviorTreeDiagramLayout
  private let selection: Binding<BehaviorNodeID?>?

  /// Creates a view driven by snapshots supplied by its parent.
  public init(
    definition: BehaviorTreeDefinition,
    snapshot: BehaviorVisualizationSnapshot? = nil,
    layout: BehaviorTreeDiagramLayout = .init()
  ) {
    self.definition = definition
    preparedDiagram = nil
    self.snapshot = snapshot
    visualization = nil
    self.layout = layout
    selection = nil
  }

  /// Creates a view driven by snapshots while exposing node selection.
  public init(
    definition: BehaviorTreeDefinition,
    snapshot: BehaviorVisualizationSnapshot? = nil,
    selection: Binding<BehaviorNodeID?>,
    layout: BehaviorTreeDiagramLayout = .init()
  ) {
    self.definition = definition
    preparedDiagram = nil
    self.snapshot = snapshot
    visualization = nil
    self.layout = layout
    self.selection = selection
  }

  /// Creates a view from a precomputed diagram and an optional snapshot.
  public init(
    diagram: BehaviorTreeDiagram,
    snapshot: BehaviorVisualizationSnapshot? = nil
  ) {
    definition = diagram.definition
    preparedDiagram = diagram
    self.snapshot = snapshot
    visualization = nil
    layout = .init()
    selection = nil
  }

  /// Creates a self-updating view backed by a visualization store.
  public init(
    visualization: BehaviorVisualizationStore,
    layout: BehaviorTreeDiagramLayout = .init()
  ) {
    definition = visualization.definition
    preparedDiagram = nil
    snapshot = nil
    self.visualization = visualization
    self.layout = layout
    selection = nil
  }

  /// Creates a self-updating view with a precomputed diagram.
  public init(
    diagram: BehaviorTreeDiagram,
    visualization: BehaviorVisualizationStore
  ) {
    precondition(diagram.definition == visualization.definition)
    definition = diagram.definition
    preparedDiagram = diagram
    snapshot = nil
    self.visualization = visualization
    layout = .init()
    selection = nil
  }

  public var body: some View {
    let activeDiagram =
      preparedDiagram
      ?? generatedDiagram.flatMap { $0.definition == definition ? $0 : nil }
    let proposedSnapshot = visualization == nil ? snapshot : liveSnapshot
    let activeSnapshot = proposedSnapshot.flatMap {
      $0.treeName == definition.name && $0.treeVersion == definition.version
        ? $0
        : nil
    }
    BehaviorTreeViewContent(
      definition: definition,
      diagram: activeDiagram,
      diagramFailure: diagramFailure,
      snapshot: activeSnapshot,
      selection: selection ?? $internalSelection,
      configuration: configuration,
      theme: theme
    )
    .task(id: DiagramTaskID(definition: definition, layout: layout)) {
      await prepareDiagramIfNeeded()
    }
    .task(id: visualization.map(ObjectIdentifier.init)) {
      await observeVisualizationIfNeeded()
    }
  }

  private func prepareDiagramIfNeeded() async {
    guard preparedDiagram == nil else { return }
    let definition = definition
    let layout = layout
    do {
      let diagram = try await Task.detached(priority: .userInitiated) {
        try BehaviorTreeDiagram(definition: definition, layout: layout)
      }.value
      guard !Task.isCancelled else { return }
      generatedDiagram = diagram
      diagramFailure = nil
    } catch is CancellationError {
      return
    } catch let error as BehaviorTreeDiagramError {
      guard !Task.isCancelled else { return }
      diagramFailure = error
    } catch {
      guard !Task.isCancelled else { return }
      diagramFailure = .layoutFailed(String(describing: error))
    }
  }

  private func observeVisualizationIfNeeded() async {
    guard let visualization else { return }
    for await next in visualization.makeSnapshotStream(bufferingNewest: 1) {
      guard !Task.isCancelled else { return }
      if liveSnapshot != next { liveSnapshot = next }
    }
  }
}

private struct DiagramTaskID: Hashable {
  let definition: BehaviorTreeDefinition
  let layout: BehaviorTreeDiagramLayout
}

private struct SelectionFocusRequest: Hashable {
  let definition: BehaviorTreeDefinition
  let selectedNodeID: BehaviorNodeID?
  let isEnabled: Bool
}

private struct BehaviorTreeViewport: Equatable {
  var offset = CGSize.zero
  var scale: CGFloat
}

private struct BehaviorTreeViewContent: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let definition: BehaviorTreeDefinition
  let diagram: BehaviorTreeDiagram?
  let diagramFailure: BehaviorTreeDiagramError?
  let snapshot: BehaviorVisualizationSnapshot?
  @Binding var selectedNodeID: BehaviorNodeID?
  let configuration: BehaviorTreeViewConfiguration
  let theme: BehaviorTreeViewTheme

  @State private var viewport = BehaviorTreeViewport(scale: 1)
  @State private var viewportDefinition: BehaviorTreeDefinition?
  @State private var pulsedNodeID: BehaviorNodeID?
  @State private var eventPulse: CGFloat = 0
  @GestureState private var dragTranslation = CGSize.zero
  #if !os(tvOS) && !os(watchOS)
    @GestureState private var gestureMagnification: CGFloat = 1
  #endif

  init(
    definition: BehaviorTreeDefinition,
    diagram: BehaviorTreeDiagram?,
    diagramFailure: BehaviorTreeDiagramError?,
    snapshot: BehaviorVisualizationSnapshot?,
    selection: Binding<BehaviorNodeID?>,
    configuration: BehaviorTreeViewConfiguration,
    theme: BehaviorTreeViewTheme
  ) {
    self.definition = definition
    self.diagram = diagram
    self.diagramFailure = diagramFailure
    self.snapshot = snapshot
    _selectedNodeID = selection
    self.configuration = configuration
    self.theme = theme
    _viewport = State(
      initialValue: BehaviorTreeViewport(scale: configuration.initialZoom)
    )
  }

  var body: some View {
    GeometryReader { geometry in
      if let diagram {
        interactiveDiagram(diagram, in: geometry.size)
      } else if let diagramFailure {
        ContentUnavailableView(
          "Unable to lay out behavior tree",
          systemImage: "exclamationmark.triangle",
          description: Text(String(describing: diagramFailure))
        )
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel("Laying out behavior tree")
      }
    }
    .background(theme.backgroundColor)
    .clipped()
    .onChange(of: diagram?.definition) {
      viewport = BehaviorTreeViewport(scale: configuration.initialZoom)
      if let selectedNodeID,
        definition.node(identifiedBy: selectedNodeID) == nil
      {
        self.selectedNodeID = nil
      }
    }
    .task(id: snapshot?.sequence) {
      await animateLatestEvent()
    }
  }

  @ViewBuilder
  private func interactiveDiagram(
    _ diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> some View {
    diagramCanvas(diagram, in: size)
      .task(id: diagram.definition) {
        positionInitialViewport(for: diagram)
      }
      .task(
        id: SelectionFocusRequest(
          definition: diagram.definition,
          selectedNodeID: selectedNodeID,
          isEnabled: configuration.centersSelection
        )
      ) {
        centerSelectionIfNeeded(in: diagram, size: size)
      }
  }

  private func positionInitialViewport(for diagram: BehaviorTreeDiagram) {
    guard viewportDefinition != diagram.definition,
      let root = diagram.nodes.first(where: { $0.id == diagram.definition.root.id })
    else { return }
    viewport = BehaviorTreeViewport(
      offset: CGSize(
        width: (diagram.contentBounds.midX - root.frame.midX) * configuration.initialZoom,
        height: (diagram.contentBounds.midY - root.frame.midY) * configuration.initialZoom
      ),
      scale: configuration.initialZoom
    )
    viewportDefinition = diagram.definition
  }

  private func diagramCanvas(
    _ diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> some View {
    let transform = makeTransform(for: diagram, in: size)
    let canvas = BehaviorTreeCanvas(
      diagram: diagram,
      snapshot: snapshot,
      selectedNodeID: selectedNodeID,
      pulsedNodeID: pulsedNodeID,
      eventPulse: eventPulse,
      transform: transform,
      configuration: configuration,
      theme: theme
    )
    return interactiveCanvas(canvas, diagram: diagram, in: size)
      .overlay(alignment: .topLeading) {
        BehaviorTreeExecutionStatusView(
          definition: definition,
          snapshot: snapshot,
          theme: theme
        )
        .padding(10)
        .opacity(configuration.isExecutionStatusVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!configuration.isExecutionStatusVisible)
      }
      .overlay(alignment: .topTrailing) {
        BehaviorTreeViewportControls(
          viewport: $viewport,
          currentScale: transform.scale,
          fitScale: fitScale(for: diagram, in: size),
          configuration: configuration
        )
        .padding(10)
        .opacity(configuration.areControlsVisible ? 1 : 0)
        .allowsHitTesting(configuration.areControlsVisible)
        .accessibilityHidden(!configuration.areControlsVisible)
      }
      .overlay(alignment: .bottomTrailing) {
        BehaviorTreeLegend(theme: theme)
          .padding(10)
          .opacity(configuration.isLegendVisible ? 1 : 0)
          .allowsHitTesting(false)
          .accessibilityHidden(!configuration.isLegendVisible)
      }
      .overlay(alignment: .bottomLeading) {
        if configuration.isInspectorVisible,
          let selectedNodeID,
          let node = diagram.nodes.first(where: { $0.id == selectedNodeID })
        {
          BehaviorTreeNodeInspector(
            node: node,
            state: snapshot?.nodes[selectedNodeID],
            theme: theme,
            selection: $selectedNodeID
          )
          .padding(10)
        }
      }
  }

  @ViewBuilder
  private func interactiveCanvas<Content: View>(
    _ content: Content,
    diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> some View {
    #if os(tvOS)
      content
    #else
      content
        .contentShape(Rectangle())
        .gesture(panGesture, isEnabled: configuration.isPanEnabled)
        #if os(macOS) || os(iOS) || os(visionOS)
          .simultaneousGesture(
            zoomGesture(diagram, in: size),
            isEnabled: configuration.isZoomEnabled
          )
        #endif
        .simultaneousGesture(
          selectionGesture(diagram, in: size),
          isEnabled: configuration.isSelectionEnabled
        )
    #endif
  }

  #if !os(tvOS)
    private var panGesture: some Gesture {
      DragGesture(minimumDistance: 2)
        .updating($dragTranslation) { value, state, _ in
          state = value.translation
        }
        .onEnded { value in
          viewport.offset.width += value.translation.width
          viewport.offset.height += value.translation.height
        }
    }
  #endif

  #if !os(tvOS) && !os(watchOS)
    private func zoomGesture(
      _ diagram: BehaviorTreeDiagram,
      in size: CGSize
    ) -> some Gesture {
      MagnifyGesture()
        .updating($gestureMagnification) { value, state, _ in
          state = value.magnification
        }
        .onEnded { value in
          viewport.scale = clampedScale(viewport.scale * value.magnification)
        }
    }
  #endif

  #if !os(tvOS)
    private func selectionGesture(
      _ diagram: BehaviorTreeDiagram,
      in size: CGSize
    ) -> some Gesture {
      SpatialTapGesture()
        .onEnded { value in
          let point = diagramPoint(
            from: value.location,
            diagram: diagram,
            in: size
          )
          guard let node = diagram.nodes.last(where: { $0.frame.contains(point) }) else {
            return
          }
          selectedNodeID = node.id
        }
    }
  #endif

  private func makeTransform(
    for diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> BehaviorTreeCanvasTransform {
    guard size.width > 0, size.height > 0 else {
      return BehaviorTreeCanvasTransform(scale: 1, offset: .zero)
    }
    let baseScale = viewport.scale
    #if !os(tvOS) && !os(watchOS)
      let gestureZoom = gestureMagnification
    #else
      let gestureZoom: CGFloat = 1
    #endif
    let proposedScale = baseScale * gestureZoom
    let scale =
      configuration.isZoomEnabled
      ? clampedScale(proposedScale)
      : baseScale
    let drag = configuration.isPanEnabled ? dragTranslation : .zero
    let storedOffset = configuration.isPanEnabled ? viewport.offset : .zero
    return BehaviorTreeCanvasTransform(
      scale: scale,
      offset: CGSize(
        width: storedOffset.width + drag.width,
        height: storedOffset.height + drag.height
      )
    )
  }

  private func fitScale(
    for diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> CGFloat {
    let availableWidth = max(1, size.width - 96)
    let availableHeight = max(1, size.height - 128)
    return min(
      1,
      min(
        availableWidth / diagram.contentBounds.width,
        availableHeight / diagram.contentBounds.height
      )
    )
  }

  private func centerSelectionIfNeeded(
    in diagram: BehaviorTreeDiagram,
    size: CGSize
  ) {
    guard configuration.centersSelection,
      let selectedNodeID,
      let node = diagram.nodes.first(where: { $0.id == selectedNodeID })
    else { return }
    let scale = viewport.scale
    viewport.offset = CGSize(
      width: (diagram.contentBounds.midX - node.frame.midX) * scale,
      height: (diagram.contentBounds.midY - node.frame.midY) * scale
    )
  }

  private func diagramPoint(
    from viewPoint: CGPoint,
    diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> CGPoint {
    let transform = makeTransform(for: diagram, in: size)
    return CGPoint(
      x: (viewPoint.x - size.width / 2 - transform.offset.width)
        / transform.scale + diagram.contentBounds.midX,
      y: (viewPoint.y - size.height / 2 - transform.offset.height)
        / transform.scale + diagram.contentBounds.midY
    )
  }

  private func clampedScale(_ proposed: CGFloat) -> CGFloat {
    min(configuration.maximumZoom, max(configuration.minimumZoom, proposed))
  }

  private func animateLatestEvent() async {
    pulsedNodeID = snapshot?.latestEvent?.nodeID
    guard pulsedNodeID != nil, !reduceMotion else {
      eventPulse = 0
      return
    }
    eventPulse = 1
    await Task.yield()
    guard !Task.isCancelled else { return }
    withAnimation(.smooth(duration: 0.5)) {
      eventPulse = 0
    }
  }
}

private struct BehaviorTreeCanvasTransform: Equatable {
  let scale: CGFloat
  let offset: CGSize
}

private struct BehaviorTreeCanvasAnimation: VectorArithmetic, Sendable {
  static let headerCount = 4
  static let nodeStride = 8
  static let statuses: [BehaviorVisualizationStatus] = [
    .idle, .running, .succeeded, .failed, .skipped, .cancelled,
  ]

  var values: [Double]

  static let zero = Self(values: [])

  static func + (lhs: Self, rhs: Self) -> Self {
    combine(lhs, rhs, using: +)
  }

  static func - (lhs: Self, rhs: Self) -> Self {
    combine(lhs, rhs, using: -)
  }

  mutating func scale(by rhs: Double) {
    for index in values.indices {
      values[index] *= rhs
    }
  }

  var magnitudeSquared: Double {
    values.reduce(into: 0) { result, value in
      result += value * value
    }
  }

  init(values: [Double]) {
    self.values = values
  }

  init(
    diagram: BehaviorTreeDiagram,
    snapshot: BehaviorVisualizationSnapshot?,
    eventPulse: CGFloat,
    transform: BehaviorTreeCanvasTransform
  ) {
    var values = [
      Double(eventPulse),
      Double(transform.scale),
      Double(transform.offset.width),
      Double(transform.offset.height),
    ]
    values.reserveCapacity(
      Self.headerCount + diagram.nodes.count * Self.nodeStride
    )
    for node in diagram.nodes {
      let state = snapshot?.nodes[node.id]
      let status = state?.status ?? .idle
      for candidate in Self.statuses {
        values.append(candidate == status ? 1 : 0)
      }
      let progress = progressFraction(state?.progress)
      values.append(Double(progress ?? 0))
      values.append(progress == nil ? 0 : 1)
    }
    self.values = values
  }

  func value(at index: Int) -> Double {
    self[index]
  }

  private static func combine(
    _ lhs: Self,
    _ rhs: Self,
    using operation: (Double, Double) -> Double
  ) -> Self {
    let count = max(lhs.values.count, rhs.values.count)
    return Self(
      values: (0..<count).map { index in
        operation(lhs[index], rhs[index])
      }
    )
  }

  private subscript(index: Int) -> Double {
    values.indices.contains(index) ? values[index] : 0
  }
}

private struct BehaviorTreeCanvas: View, Animatable {
  let diagram: BehaviorTreeDiagram
  let snapshot: BehaviorVisualizationSnapshot?
  let selectedNodeID: BehaviorNodeID?
  let pulsedNodeID: BehaviorNodeID?
  let configuration: BehaviorTreeViewConfiguration
  let theme: BehaviorTreeViewTheme
  var canvasAnimation: BehaviorTreeCanvasAnimation

  init(
    diagram: BehaviorTreeDiagram,
    snapshot: BehaviorVisualizationSnapshot?,
    selectedNodeID: BehaviorNodeID?,
    pulsedNodeID: BehaviorNodeID?,
    eventPulse: CGFloat,
    transform: BehaviorTreeCanvasTransform,
    configuration: BehaviorTreeViewConfiguration,
    theme: BehaviorTreeViewTheme
  ) {
    self.diagram = diagram
    self.snapshot = snapshot
    self.selectedNodeID = selectedNodeID
    self.pulsedNodeID = pulsedNodeID
    self.configuration = configuration
    self.theme = theme
    canvasAnimation = BehaviorTreeCanvasAnimation(
      diagram: diagram,
      snapshot: snapshot,
      eventPulse: eventPulse,
      transform: transform
    )
  }

  nonisolated var animatableData: BehaviorTreeCanvasAnimation {
    get { canvasAnimation }
    set { canvasAnimation = newValue }
  }

  private var eventPulse: CGFloat {
    CGFloat(canvasAnimation.value(at: 0))
  }

  private var transform: BehaviorTreeCanvasTransform {
    BehaviorTreeCanvasTransform(
      scale: CGFloat(canvasAnimation.value(at: 1)),
      offset: CGSize(
        width: canvasAnimation.value(at: 2),
        height: canvasAnimation.value(at: 3)
      )
    )
  }

  var body: some View {
    Canvas(
      opaque: false,
      colorMode: .nonLinear,
      rendersAsynchronously: configuration.rendersAsynchronously
    ) { context, size in
      render(in: &context, size: size)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Behavior tree \(diagram.definition.name)")
    .accessibilityValue(accessibilitySummary)
  }

  private func render(
    in context: inout GraphicsContext,
    size: CGSize
  ) {
    guard transform.scale > 0 else { return }
    let visibleBounds = visibleDiagramBounds(in: size)
    let frontier = frontierNodeIDs()
    context.translateBy(
      x: size.width / 2 + transform.offset.width,
      y: size.height / 2 + transform.offset.height
    )
    context.scaleBy(x: transform.scale, y: transform.scale)
    context.translateBy(
      x: -diagram.contentBounds.midX,
      y: -diagram.contentBounds.midY
    )

    for group in diagram.groups where group.frame.intersects(visibleBounds) {
      draw(group, in: &context)
    }
    for edge in diagram.edges where edge.bounds.intersects(visibleBounds) {
      draw(edge, frontier: frontier, in: &context)
    }
    for (nodeIndex, node) in diagram.nodes.enumerated()
    where node.frame.intersects(visibleBounds) {
      draw(
        node,
        nodeIndex: nodeIndex,
        isSelected: node.id == selectedNodeID,
        frontier: frontier,
        in: &context
      )
    }
  }

  private func visibleDiagramBounds(in size: CGSize) -> CGRect {
    let origin = CGPoint(
      x: (-size.width / 2 - transform.offset.width) / transform.scale
        + diagram.contentBounds.midX,
      y: (-size.height / 2 - transform.offset.height) / transform.scale
        + diagram.contentBounds.midY
    )
    return CGRect(
      origin: origin,
      size: CGSize(
        width: size.width / transform.scale,
        height: size.height / transform.scale
      )
    ).insetBy(dx: -8, dy: -8)
  }

  private func frontierNodeIDs() -> Set<BehaviorNodeID> {
    guard let snapshot else { return [] }
    let running = Set(
      snapshot.nodes.compactMap { entry in
        entry.value.status == .running ? entry.key : nil
      })
    return Set(
      diagram.nodes.compactMap { node in
        guard running.contains(node.id) else { return nil }
        return node.childIDs.contains(where: running.contains) ? nil : node.id
      })
  }

  private func draw(
    _ group: BehaviorTreeDiagramGroup,
    in context: inout GraphicsContext
  ) {
    let dash: [CGFloat] =
      switch group.kind {
      case .execution: [7, 5]
      case .parallel: []
      case .decision: [3, 3]
      case .loop: [10, 4]
      case .fanOut: [2, 4]
      }
    let shape = Path(roundedRect: group.frame, cornerRadius: 18)
    context.fill(shape, with: .color(theme.executionGroupFillColor))
    context.stroke(
      shape,
      with: .color(theme.executionGroupBorderColor),
      style: StrokeStyle(lineWidth: 1, dash: dash)
    )
    var label = context.resolve(Text(verbatim: group.label).font(.caption.weight(.medium)))
    label.shading = .color(theme.executionGroupTextColor)
    context.draw(
      label,
      at: CGPoint(x: group.frame.minX + 14, y: group.frame.minY + 10),
      anchor: .leading
    )
  }

  private func draw(
    _ edge: BehaviorTreeDiagramEdge,
    frontier: Set<BehaviorNodeID>,
    in context: inout GraphicsContext
  ) {
    let isSearchRelevant = searchIncludes(edge.parentID) || searchIncludes(edge.childID)
    var path = Path()
    guard let first = edge.points.first else { return }
    path.move(to: first)
    for point in edge.points.dropFirst() { path.addLine(to: point) }
    guard let childIndex = diagram.nodeIndexByID[edge.childID] else { return }
    for status in BehaviorTreeCanvasAnimation.statuses {
      let weight = statusWeight(status, nodeIndex: childIndex)
      guard weight > 0.001 else { continue }
      let color =
        status == .idle
        ? theme.edgeColor
        : renderedStyle(for: status, nodeID: edge.childID).borderColor
      let lineWidth: CGFloat
      if status == .running {
        lineWidth =
          frontier.contains(edge.childID)
          ? theme.frontierLineWidth
          : theme.runningLineWidth
      } else {
        lineWidth = status == .idle ? 1 : 1.25
      }
      context.drawLayer { layer in
        layer.opacity = weight * (isSearchRelevant ? 1 : 0.16)
        layer.stroke(
          path,
          with: .color(color),
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: status == .skipped || status == .cancelled || edge.kind == .auxiliary
              ? [6, 4] : []
          )
        )
        if edge.kind != .auxiliary, let marker = flowMarker(for: edge) {
          layer.fill(marker, with: .color(color))
        }
      }
    }
    guard configuration.details.contains(.edgeRoles),
      let role = edge.label,
      let rolePosition = edge.labelPosition
    else { return }
    var label = context.resolve(Text(verbatim: role).font(.caption2))
    label.shading = .color(theme.edgeTextColor)
    let measured = label.measure(in: CGSize(width: 180, height: 40))
    let background = CGRect(
      x: rolePosition.x - measured.width / 2 - 5,
      y: rolePosition.y - measured.height / 2 - 3,
      width: measured.width + 10,
      height: measured.height + 6
    )
    context.fill(
      Path(roundedRect: background, cornerRadius: 5),
      with: .color(.primary.opacity(0.12))
    )
    context.draw(
      label,
      at: rolePosition,
      anchor: .center
    )
  }

  private func flowMarker(for edge: BehaviorTreeDiagramEdge) -> Path? {
    guard let end = edge.points.last,
      let previous = edge.points.dropLast().last
    else { return nil }
    let delta = CGVector(dx: end.x - previous.x, dy: end.y - previous.y)
    let length = hypot(delta.dx, delta.dy)
    guard length > 0 else { return nil }
    let direction = CGVector(dx: delta.dx / length, dy: delta.dy / length)
    let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
    let base = CGPoint(
      x: end.x - direction.dx * 7,
      y: end.y - direction.dy * 7
    )
    var marker = Path()
    marker.move(to: end)
    marker.addLine(
      to: CGPoint(
        x: base.x + perpendicular.dx * 3.5,
        y: base.y + perpendicular.dy * 3.5
      )
    )
    marker.addLine(
      to: CGPoint(
        x: base.x - perpendicular.dx * 3.5,
        y: base.y - perpendicular.dy * 3.5
      )
    )
    marker.closeSubpath()
    return marker
  }

  private func draw(
    _ node: BehaviorTreeDiagramNode,
    nodeIndex: Int,
    isSelected: Bool,
    frontier: Set<BehaviorNodeID>,
    in context: inout GraphicsContext
  ) {
    let state = snapshot?.nodes[node.id]
    let status = dominantStatus(nodeIndex: nodeIndex)
    let style = renderedStyle(for: status, nodeID: node.id)
    let path = Path(roundedRect: node.frame, cornerRadius: 12)
    let isReactive = node.attributes["memory"] == .string("reactive")
    let searchOpacity: Double = searchIncludes(node.id) ? 1 : 0.18
    for candidate in BehaviorTreeCanvasAnimation.statuses {
      let weight = statusWeight(candidate, nodeIndex: nodeIndex)
      guard weight > 0.001 else { continue }
      let candidateStyle = renderedStyle(for: candidate, nodeID: node.id)
      let lineWidth =
        candidate == .running
        ? (frontier.contains(node.id)
          ? theme.frontierLineWidth : theme.runningLineWidth)
        : 1
      let isDashed = candidate == .skipped || candidate == .cancelled || isReactive
      context.drawLayer { layer in
        layer.opacity = weight * searchOpacity
        layer.fill(path, with: .color(candidateStyle.fillColor))
        layer.stroke(
          path,
          with: .color(candidateStyle.borderColor),
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineJoin: .round,
            dash: isDashed ? [6, 4] : []
          )
        )
      }
    }
    drawNodeEmphasis(
      node,
      status: status,
      style: style,
      isFrontier: frontier.contains(node.id),
      in: &context
    )
    if isSelected {
      context.stroke(
        path,
        with: .color(.accentColor),
        lineWidth: max(2, theme.runningLineWidth)
      )
    }
    if configuration.highlightedNodeIDs?.contains(node.id) == true {
      context.stroke(
        Path(roundedRect: node.frame.insetBy(dx: -3, dy: -3), cornerRadius: 15),
        with: .color(.accentColor.opacity(0.72)),
        lineWidth: 2
      )
    }

    if node.kind == .subtree {
      context.stroke(
        Path(roundedRect: node.frame.insetBy(dx: 4, dy: 4), cornerRadius: 9),
        with: .color(style.borderColor.opacity(0.7)),
        lineWidth: 1
      )
    }

    drawNodeContents(
      node,
      nodeIndex: nodeIndex,
      state: state,
      style: style,
      in: &context
    )
  }

  private func searchIncludes(_ nodeID: BehaviorNodeID) -> Bool {
    guard let highlightedNodeIDs = configuration.highlightedNodeIDs else { return true }
    return highlightedNodeIDs.contains(nodeID)
  }

  private func drawNodeEmphasis(
    _ node: BehaviorTreeDiagramNode,
    status: BehaviorVisualizationStatus,
    style: BehaviorTreeViewNodeStyle,
    isFrontier: Bool,
    in context: inout GraphicsContext
  ) {
    if status == .running, isFrontier {
      context.stroke(
        Path(roundedRect: node.frame.insetBy(dx: -4, dy: -4), cornerRadius: 15),
        with: .color(style.borderColor.opacity(0.24)),
        lineWidth: 2
      )
    }
    guard pulsedNodeID == node.id, eventPulse > 0 else { return }
    let expansion = 4 + 4 * eventPulse
    context.stroke(
      Path(
        roundedRect: node.frame.insetBy(dx: -expansion, dy: -expansion),
        cornerRadius: 15 + expansion / 2
      ),
      with: .color(style.borderColor.opacity(0.42 * eventPulse)),
      lineWidth: 2
    )
  }

  private func nodeDetail(
    _ node: BehaviorTreeDiagramNode,
    _ state: BehaviorNodeVisualizationState?
  ) -> String {
    var parts = [nodeKindLabel(node.kind)]
    guard let state, state.status != .idle else {
      return parts.joined(separator: " · ")
    }
    if configuration.details.contains(.status) {
      parts.append(nodeStatusLabel(node, state: state))
    }
    if configuration.details.contains(.attempt), let attempt = state.attempt {
      parts.append("attempt \(attempt)")
    }
    if configuration.details.contains(.progress), let progress = state.progress {
      if let completed = progress.completed, let total = progress.total {
        parts.append("\(completed)/\(total)")
      } else if let fraction = progress.fraction {
        parts.append("\(Int((fraction * 100).rounded()))%")
      }
    }
    if configuration.details.contains(.diagnostic), let diagnostic = state.diagnostic {
      parts.append(abbreviated(diagnostic.summary ?? diagnostic.code, limit: 26))
    }
    if configuration.details.contains(.inspection),
      let summary = state.inspection?.summary
    {
      parts.append(abbreviated(summary, limit: 26))
    }
    return parts.joined(separator: " · ")
  }

  private func drawNodeContents(
    _ node: BehaviorTreeDiagramNode,
    nodeIndex: Int,
    state: BehaviorNodeVisualizationState?,
    style: BehaviorTreeViewNodeStyle,
    in context: inout GraphicsContext
  ) {
    let iconCenter = CGPoint(x: node.frame.minX + 22, y: node.frame.midY)
    let iconBackground = CGRect(
      x: iconCenter.x - 12,
      y: iconCenter.y - 12,
      width: 24,
      height: 24
    )
    context.fill(
      Path(ellipseIn: iconBackground),
      with: .color(style.borderColor.opacity(0.14))
    )
    var icon = context.resolve(
      Text(Image(systemName: nodeKindSymbol(node.kind)))
        .font(.caption.weight(.semibold))
    )
    icon.shading = .color(style.borderColor)
    context.draw(icon, at: iconCenter, anchor: .center)

    let textX = node.frame.minX + 42
    let textWidth = node.frame.maxX - textX - 28
    var label = context.resolve(
      Text(verbatim: abbreviated(node.label, limit: 42))
        .font(.caption.weight(.semibold))
    )
    label.shading = .color(style.textColor)
    context.draw(
      label,
      in: CGRect(
        x: textX,
        y: node.frame.minY + 8,
        width: textWidth,
        height: 26
      )
    )

    var detail = context.resolve(
      Text(verbatim: abbreviated(nodeDetail(node, state), limit: 34))
        .font(.caption2)
    )
    detail.shading = .color(style.textColor.opacity(0.68))
    context.draw(
      detail,
      in: CGRect(
        x: textX,
        y: node.frame.minY + 38,
        width: textWidth,
        height: 18
      )
    )

    let progress = visualProgress(nodeIndex: nodeIndex)
    drawProgress(
      fraction: progress.fraction,
      visibility: progress.visibility,
      in: node.frame,
      color: style.borderColor,
      context: &context
    )
    drawStatus(
      nodeIndex: nodeIndex,
      in: node.frame,
      context: &context
    )
  }

  private func drawProgress(
    fraction: CGFloat,
    visibility: Double,
    in frame: CGRect,
    color: Color,
    context: inout GraphicsContext
  ) {
    guard visibility > 0.001 else { return }
    let track = CGRect(
      x: frame.minX + 42,
      y: frame.maxY - 9,
      width: frame.width - 54,
      height: 3
    )
    context.fill(
      Path(roundedRect: track, cornerRadius: 1.5),
      with: .color(color.opacity(0.15 * visibility))
    )
    let fill = CGRect(
      x: track.minX,
      y: track.minY,
      width: track.width * fraction,
      height: track.height
    )
    context.fill(
      Path(roundedRect: fill, cornerRadius: 1.5),
      with: .color(color.opacity(0.9 * visibility))
    )
  }

  private func drawStatus(
    nodeIndex: Int,
    in frame: CGRect,
    context: inout GraphicsContext
  ) {
    for status in BehaviorTreeCanvasAnimation.statuses {
      let weight = statusWeight(status, nodeIndex: nodeIndex)
      guard weight > 0.001, let symbol = statusSymbol(status) else { continue }
      var badge = context.resolve(
        Text(Image(systemName: symbol))
          .font(.caption2.weight(.bold))
      )
      badge.shading = .color(renderedStyle(for: status, nodeID: nodeID(at: nodeIndex)).borderColor)
      context.drawLayer { layer in
        layer.opacity = weight
        layer.draw(
          badge,
          at: CGPoint(x: frame.maxX - 13, y: frame.minY + 13),
          anchor: .center
        )
      }
    }
  }

  private func statusWeight(
    _ status: BehaviorVisualizationStatus,
    nodeIndex: Int
  ) -> Double {
    guard let statusIndex = BehaviorTreeCanvasAnimation.statuses.firstIndex(of: status) else {
      return 0
    }
    let index =
      BehaviorTreeCanvasAnimation.headerCount
      + nodeIndex * BehaviorTreeCanvasAnimation.nodeStride
      + statusIndex
    return min(1, max(0, canvasAnimation.value(at: index)))
  }

  private func nodeID(at index: Int) -> BehaviorNodeID {
    diagram.nodes[index].id
  }

  private func renderedStyle(
    for status: BehaviorVisualizationStatus,
    nodeID: BehaviorNodeID
  ) -> BehaviorTreeViewNodeStyle {
    if let index = diagram.nodeIndexByID[nodeID], diagram.nodes.indices.contains(index) {
      let node = diagram.nodes[index]
      if status == .failed, isDecisionCondition(node) { return theme.noResult }
      if status == .succeeded,
        snapshot?.nodes[nodeID]?.inspection?.outcome == nil,
        node.kind.isControlFlow
      {
        return theme.completed
      }
    }
    return theme.nodeStyle(
      for: status,
      inspectionOutcome: snapshot?.nodes[nodeID]?.inspection?.outcome
    )
  }

  private func isDecisionCondition(_ node: BehaviorTreeDiagramNode) -> Bool {
    guard node.kind == .condition,
      let parentID = node.parentID,
      let parentIndex = diagram.nodeIndexByID[parentID],
      diagram.nodes.indices.contains(parentIndex)
    else { return false }
    let parent = diagram.nodes[parentIndex]
    return parent.kind == .branch || parent.kind == .precondition || parent.kind == .loop
  }

  private func nodeStatusLabel(
    _ node: BehaviorTreeDiagramNode,
    state: BehaviorNodeVisualizationState
  ) -> String {
    if state.status == .failed, isDecisionCondition(node) { return "False" }
    if state.status == .succeeded {
      switch state.inspection?.outcome {
      case .completed: return "Completed"
      case .noResult: return "No result"
      case .produced: break
      case nil where node.kind.isControlFlow: return "Completed"
      case nil: break
      }
    }
    return state.status.rawValue.capitalized
  }

  private func dominantStatus(
    nodeIndex: Int
  ) -> BehaviorVisualizationStatus {
    BehaviorTreeCanvasAnimation.statuses.max { lhs, rhs in
      statusWeight(lhs, nodeIndex: nodeIndex)
        < statusWeight(rhs, nodeIndex: nodeIndex)
    } ?? .idle
  }

  private func visualProgress(
    nodeIndex: Int
  ) -> (fraction: CGFloat, visibility: Double) {
    let base =
      BehaviorTreeCanvasAnimation.headerCount
      + nodeIndex * BehaviorTreeCanvasAnimation.nodeStride
      + BehaviorTreeCanvasAnimation.statuses.count
    return (
      CGFloat(min(1, max(0, canvasAnimation.value(at: base)))),
      min(1, max(0, canvasAnimation.value(at: base + 1)))
    )
  }

  private var accessibilitySummary: String {
    guard let snapshot else { return "Idle" }
    var running = 0
    var succeeded = 0
    var failed = 0
    for state in snapshot.nodes.values {
      switch state.status {
      case .running: running += 1
      case .succeeded: succeeded += 1
      case .failed: failed += 1
      case .idle, .skipped, .cancelled: break
      }
    }
    return "\(snapshot.status.rawValue), event \(snapshot.sequence), "
      + "\(running) running, \(succeeded) succeeded, \(failed) failed"
  }
}

private extension BehaviorNodeKind {
  var isControlFlow: Bool {
    switch self {
    case .action, .condition, .wait, .waitForever: false
    case .sequence, .selector, .parallel, .branch, .subtree, .dynamicSubtrees,
      .retry, .repeatBehavior, .untilFailure, .inverter, .forceSuccess,
      .forceFailure, .timeout, .precondition, .lifecycle, .orderedSuccess,
      .loop, .succeed, .fail:
      true
    }
  }
}

private struct BehaviorTreeExecutionStatusView: View {
  let definition: BehaviorTreeDefinition
  let snapshot: BehaviorVisualizationSnapshot?
  let theme: BehaviorTreeViewTheme

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(theme.nodeStyle(for: visualizationStatus).borderColor)
        .frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: definition.name)
          .font(.caption.weight(.semibold))
        Text(verbatim: statusText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }

  private var visualizationStatus: BehaviorVisualizationStatus {
    switch snapshot?.status ?? .idle {
    case .idle: .idle
    case .running: .running
    case .succeeded: .succeeded
    case .failed: .failed
    case .cancelled: .cancelled
    }
  }

  private var statusText: String {
    guard let snapshot else { return "idle" }
    return "\(snapshot.status.rawValue) · event \(snapshot.sequence)"
  }
}

private struct BehaviorTreeViewportControls: View {
  @Binding var viewport: BehaviorTreeViewport
  let currentScale: CGFloat
  let fitScale: CGFloat
  let configuration: BehaviorTreeViewConfiguration

  var body: some View {
    HStack(spacing: 4) {
      Button(action: zoomOut) {
        Label("Zoom out", systemImage: "minus.magnifyingglass")
      }
      .frame(width: 26, height: 24)
      .disabled(!configuration.isZoomEnabled)

      Button(action: reset) {
        Label("Fit tree", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
      }
      .frame(width: 26, height: 24)
      .disabled(!configuration.isZoomEnabled && !configuration.isPanEnabled)

      Button(action: zoomIn) {
        Label("Zoom in", systemImage: "plus.magnifyingglass")
      }
      .frame(width: 26, height: 24)
      .disabled(!configuration.isZoomEnabled)

      Button(action: actualSize) {
        Label("Actual size", systemImage: "1.magnifyingglass")
      }
      .frame(width: 26, height: 24)
      .disabled(!configuration.isZoomEnabled)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.plain)
    .controlSize(.small)
    .padding(4)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
  }

  private func zoomOut() {
    viewport.scale = max(configuration.minimumZoom, currentScale / 1.25)
  }

  private func reset() {
    viewport = BehaviorTreeViewport(
      offset: .zero,
      scale: min(configuration.maximumZoom, max(configuration.minimumZoom, fitScale))
    )
  }

  private func zoomIn() {
    viewport.scale = min(configuration.maximumZoom, currentScale * 1.25)
  }

  private func actualSize() {
    viewport.scale = min(configuration.maximumZoom, max(configuration.minimumZoom, 1))
  }
}

private struct BehaviorTreeLegend: View {
  let theme: BehaviorTreeViewTheme

  var body: some View {
    HStack(spacing: 8) {
      legendItem("Running", style: theme.running)
      legendItem("Result", style: theme.succeeded)
      legendItem("Completed", style: theme.completed)
      legendItem("No result", style: theme.noResult)
      legendItem("Failed", style: theme.failed)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
    .frame(maxWidth: 340, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Behavior state legend")
  }

  private func legendItem(
    _ label: String,
    style: BehaviorTreeViewNodeStyle
  ) -> some View {
    HStack(spacing: 3) {
      Circle()
        .fill(style.borderColor)
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
      Text(verbatim: label)
        .font(.caption2)
    }
  }
}

private struct BehaviorTreeNodeInspector: View {
  @State private var didCopy = false

  let node: BehaviorTreeDiagramNode
  let state: BehaviorNodeVisualizationState?
  let theme: BehaviorTreeViewTheme
  @Binding var selection: BehaviorNodeID?

  init(
    node: BehaviorTreeDiagramNode,
    state: BehaviorNodeVisualizationState?,
    theme: BehaviorTreeViewTheme,
    selection: Binding<BehaviorNodeID?>
  ) {
    self.node = node
    self.state = state
    self.theme = theme
    _selection = selection
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12)
    VStack(alignment: .leading, spacing: 10) {
      BehaviorTreeInspectorHeader(
        title: node.label,
        kind: nodeKindLabel(node.kind),
        status: status,
        color: statusColor,
        didCopy: didCopy,
        copy: copyInspector,
        close: close
      )

      Divider()

      BehaviorTreeInspectorValueRow(
        label: "Node",
        value: node.id.rawValue
      )
      if let attempt = state?.attempt {
        BehaviorTreeInspectorValueRow(
          label: "Attempt",
          value: String(attempt)
        )
      }
      if let progress = state?.progress {
        BehaviorTreeInspectorProgress(
          progress: progress,
          color: statusColor
        )
      }
      if let diagnostic = state?.diagnostic {
        Divider()
        BehaviorTreeInspectorSectionHeader(title: "Diagnostic")
        Text(diagnostic.summary ?? diagnostic.code)
          .font(.caption)
          .foregroundStyle(statusColor)
        ForEach(diagnostic.attributes.keys.sorted(), id: \.self) { key in
          if let value = diagnostic.attributes[key] {
            BehaviorTreeInspectorValueRow(
              label: key,
              value: value.description
            )
          }
        }
      }
      if let inspection = state?.inspection {
        Divider()
        BehaviorTreeInspectorSectionHeader(title: "Inspection")
        if let outcome = inspection.outcome {
          BehaviorTreeInspectorValueRow(
            label: "Outcome",
            value: outcome.rawValue
          )
        }
        if let summary = inspection.summary {
          Text(summary)
            .font(.caption)
        }
        ForEach(inspection.values.keys.sorted(), id: \.self) { key in
          if let value = inspection.values[key] {
            BehaviorTreeInspectorValueRow(
              label: key,
              value: value.description
            )
          }
        }
      }
    }
    .padding(12)
    .frame(idealWidth: 320, maxWidth: 380, alignment: .leading)
    .background(.regularMaterial, in: shape)
    .overlay { shape.strokeBorder(.primary.opacity(0.08)) }
    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Node inspector")
    .task(id: didCopy) {
      guard didCopy else { return }
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      didCopy = false
    }
  }

  private var status: BehaviorVisualizationStatus {
    state?.status ?? .idle
  }

  private var statusColor: Color {
    theme.nodeStyle(
      for: status,
      inspectionOutcome: state?.inspection?.outcome
    ).borderColor
  }

  private func close() {
    selection = nil
  }

  private func copyInspector() {
    copyToPasteboard(inspectorText)
    didCopy = true
  }

  private var inspectorText: String {
    var lines = [
      node.label,
      "\(nodeKindLabel(node.kind)) · \(visualizationStatusLabel(status))",
      "Node: \(node.id.rawValue)",
    ]
    if let attempt = state?.attempt {
      lines.append("Attempt: \(attempt)")
    }
    if let progress = state?.progress {
      if let completed = progress.completed, let total = progress.total {
        lines.append("Progress: \(completed) of \(total)")
      } else if let fraction = progress.fraction, fraction.isFinite {
        lines.append("Progress: \(Int((min(1, max(0, fraction)) * 100).rounded()))%")
      }
      if let message = progress.message {
        lines.append(message)
      }
    }
    if let diagnostic = state?.diagnostic {
      lines.append("Diagnostic: \(diagnostic.summary ?? diagnostic.code)")
      for key in diagnostic.attributes.keys.sorted() {
        if let value = diagnostic.attributes[key] {
          lines.append("\(key): \(value)")
        }
      }
    }
    if let inspection = state?.inspection {
      if let outcome = inspection.outcome {
        lines.append("Outcome: \(outcome.rawValue)")
      }
      if let summary = inspection.summary {
        lines.append("Inspection: \(summary)")
      }
      for key in inspection.values.keys.sorted() {
        if let value = inspection.values[key] {
          lines.append("\(key): \(value)")
        }
      }
    }
    return lines.joined(separator: "\n")
  }
}

private struct BehaviorTreeInspectorHeader: View {
  let title: String
  let kind: String
  let status: BehaviorVisualizationStatus
  let color: Color
  let didCopy: Bool
  let copy: () -> Void
  let close: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
        .padding(.top, 5)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
          .lineLimit(2)
        HStack(spacing: 6) {
          Text(kind)
            .foregroundStyle(.secondary)
          Text(statusLabel)
            .foregroundStyle(color)
        }
        .font(.caption2.weight(.medium))
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 2) {
        #if !os(watchOS)
          Button(
            didCopy ? "Copied" : "Copy inspector",
            systemImage: didCopy ? "checkmark" : "doc.on.doc",
            action: copy
          )
          .foregroundStyle(didCopy ? color : .secondary)
          .help(didCopy ? "Copied" : "Copy inspector")
        #endif
        Button("Close inspector", systemImage: "xmark", action: close)
          .foregroundStyle(.secondary)
          .help("Close inspector")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .contentShape(.rect)
      .controlSize(.small)
    }
  }

  private var statusLabel: String {
    visualizationStatusLabel(status)
  }
}

private struct BehaviorTreeInspectorProgress: View {
  let progress: BehaviorProgress
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      LabeledContent("Progress") {
        if let valueText {
          Text(valueText)
            .monospacedDigit()
            .contentTransition(.numericText())
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let fraction {
        ProgressView(value: fraction)
          .tint(color)
          .accessibilityLabel("Progress")
      }
      if let message = progress.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private var fraction: Double? {
    if let fraction = progress.fraction, fraction.isFinite {
      return min(1, max(0, fraction))
    }
    if let completed = progress.completed,
      let total = progress.total,
      total > 0
    {
      return min(1, max(0, Double(completed) / Double(total)))
    }
    return nil
  }

  private var valueText: String? {
    if let completed = progress.completed, let total = progress.total {
      return "\(completed) of \(total)"
    }
    if let fraction {
      return "\(Int((fraction * 100).rounded()))%"
    }
    return nil
  }
}

private struct BehaviorTreeInspectorSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(.uppercase)
      .tracking(0.4)
  }
}

private struct BehaviorTreeInspectorValueRow: View {
  let label: String
  let value: String

  var body: some View {
    LabeledContent {
      Text(value)
        .font(.caption.monospaced())
        .multilineTextAlignment(.trailing)
        .lineLimit(3)
        .truncationMode(.middle)
        #if os(macOS) || os(iOS) || os(visionOS)
          .textSelection(.enabled)
        #endif
    } label: {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    #if os(macOS) || os(iOS) || os(visionOS)
      .contextMenu {
        Button("Copy value", systemImage: "doc.on.doc") {
          copyToPasteboard(value)
        }
        Button("Copy field", systemImage: "list.bullet.clipboard") {
          copyToPasteboard("\(label): \(value)")
        }
      }
    #endif
  }
}

private func visualizationStatusLabel(
  _ status: BehaviorVisualizationStatus
) -> String {
  switch status {
  case .idle: "Idle"
  case .running: "Running"
  case .succeeded: "Succeeded"
  case .failed: "Failed"
  case .skipped: "Skipped"
  case .cancelled: "Cancelled"
  }
}

@MainActor
private func copyToPasteboard(_ value: String) {
  #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  #elseif os(iOS) || os(visionOS)
    UIPasteboard.general.string = value
  #endif
}

private func abbreviated(_ value: String, limit: Int) -> String {
  guard value.count > limit else { return value }
  return String(value.prefix(max(1, limit - 1))) + "…"
}

private func nodeKindLabel(_ kind: BehaviorNodeKind) -> String {
  switch kind {
  case .action: "Action"
  case .condition: "Condition"
  case .succeed: "Success"
  case .fail: "Failure"
  case .wait: "Wait"
  case .waitForever: "Wait"
  case .subtree: "Subtree"
  case .dynamicSubtrees: "Fan-out"
  case .sequence: "Sequence"
  case .selector: "Selector"
  case .branch: "Branch"
  case .parallel: "Parallel"
  case .orderedSuccess: "Ordered"
  case .loop: "Loop"
  case .retry: "Retry"
  case .repeatBehavior: "Repeat"
  case .untilFailure: "Until failure"
  case .inverter: "Invert"
  case .forceSuccess: "Force success"
  case .forceFailure: "Force failure"
  case .timeout: "Timeout"
  case .precondition: "Precondition"
  case .lifecycle: "Lifecycle"
  }
}

private func nodeKindSymbol(_ kind: BehaviorNodeKind) -> String {
  switch kind {
  case .action: "play.fill"
  case .condition: "questionmark"
  case .succeed: "checkmark"
  case .fail: "xmark"
  case .wait: "clock"
  case .waitForever: "infinity"
  case .subtree: "square.stack.3d.up"
  case .dynamicSubtrees: "folder.badge.gearshape"
  case .sequence: "arrow.right"
  case .selector, .branch: "arrow.triangle.branch"
  case .parallel: "arrow.left.arrow.right"
  case .orderedSuccess: "list.number"
  case .loop, .repeatBehavior, .untilFailure: "repeat"
  case .retry: "arrow.clockwise"
  case .inverter: "arrow.up.arrow.down"
  case .forceSuccess: "checkmark.circle"
  case .forceFailure: "xmark.circle"
  case .timeout: "timer"
  case .precondition: "checkmark.shield"
  case .lifecycle: "circle.dotted"
  }
}

private func progressFraction(_ progress: BehaviorProgress?) -> CGFloat? {
  guard let progress else { return nil }
  if let fraction = progress.fraction {
    return CGFloat(min(1, max(0, fraction)))
  }
  if let completed = progress.completed, let total = progress.total, total > 0 {
    return CGFloat(min(1, max(0, Double(completed) / Double(total))))
  }
  return nil
}

private func statusSymbol(_ status: BehaviorVisualizationStatus) -> String? {
  switch status {
  case .idle: nil
  case .running: "circle.fill"
  case .succeeded: "checkmark"
  case .failed: "xmark"
  case .skipped: "forward.end.fill"
  case .cancelled: "stop.fill"
  }
}
