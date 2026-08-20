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
  @State private var liveSnapshot: BehaviorVisualizationSnapshot?

  private let definition: BehaviorTreeDefinition
  private let preparedDiagram: BehaviorTreeDiagram?
  private let snapshot: BehaviorVisualizationSnapshot?
  private let visualization: BehaviorVisualizationStore?
  private let layout: BehaviorTreeDiagramLayout

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
      snapshot: activeSnapshot,
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
    let diagram = await Task.detached(priority: .userInitiated) {
      BehaviorTreeDiagram(definition: definition, layout: layout)
    }.value
    guard !Task.isCancelled else { return }
    generatedDiagram = diagram
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

private struct BehaviorTreeViewport: Equatable {
  var offset = CGSize.zero
  var zoom: CGFloat = 1
}

private struct BehaviorTreeViewContent: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let definition: BehaviorTreeDefinition
  let diagram: BehaviorTreeDiagram?
  let snapshot: BehaviorVisualizationSnapshot?
  let configuration: BehaviorTreeViewConfiguration
  let theme: BehaviorTreeViewTheme

  @State private var viewport = BehaviorTreeViewport()
  @State private var selectedNodeID: BehaviorNodeID?
  @State private var pulsedNodeID: BehaviorNodeID?
  @State private var eventPulse: CGFloat = 0
  @GestureState private var dragTranslation = CGSize.zero
  #if !os(tvOS) && !os(watchOS)
    @GestureState private var gestureMagnification: CGFloat = 1
  #endif

  init(
    definition: BehaviorTreeDefinition,
    diagram: BehaviorTreeDiagram?,
    snapshot: BehaviorVisualizationSnapshot?,
    configuration: BehaviorTreeViewConfiguration,
    theme: BehaviorTreeViewTheme
  ) {
    self.definition = definition
    self.diagram = diagram
    self.snapshot = snapshot
    self.configuration = configuration
    self.theme = theme
  }

  var body: some View {
    GeometryReader { geometry in
      if let diagram {
        interactiveDiagram(diagram, in: geometry.size)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel("Laying out behavior tree")
      }
    }
    .background(theme.backgroundColor)
    .clipped()
    .onChange(of: diagram?.definition) {
      viewport = BehaviorTreeViewport()
      selectedNodeID = nil
    }
    .task(id: snapshot?.sequence) {
      await animateLatestEvent()
    }
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.28),
      value: snapshot
    )
  }

  @ViewBuilder
  private func interactiveDiagram(
    _ diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> some View {
    diagramCanvas(diagram, in: size)
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
            zoomGesture,
            isEnabled: configuration.isZoomEnabled
          )
        #endif
        .simultaneousGesture(
          selectionGesture(diagram, in: size),
          isEnabled: configuration.isInspectorVisible
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
    private var zoomGesture: some Gesture {
      MagnifyGesture()
        .updating($gestureMagnification) { value, state, _ in
          state = value.magnification
        }
        .onEnded { value in
          viewport.zoom = clampedZoom(viewport.zoom * value.magnification)
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
          selectedNodeID = diagram.nodes.last { $0.frame.contains(point) }?.id
        }
    }
  #endif

  private func makeTransform(
    for diagram: BehaviorTreeDiagram,
    in size: CGSize
  ) -> BehaviorTreeCanvasTransform {
    let bounds = diagram.contentBounds
    guard size.width > 0, size.height > 0 else {
      return BehaviorTreeCanvasTransform(scale: 1, offset: .zero)
    }
    let availableWidth = max(1, size.width - 96)
    let availableHeight = max(1, size.height - 128)
    let fitScale = min(
      1,
      min(availableWidth / bounds.width, availableHeight / bounds.height)
    )
    #if !os(tvOS) && !os(watchOS)
      let gestureZoom = gestureMagnification
    #else
      let gestureZoom: CGFloat = 1
    #endif
    let zoom =
      configuration.isZoomEnabled
      ? clampedZoom(viewport.zoom * gestureZoom)
      : 1
    let drag = configuration.isPanEnabled ? dragTranslation : .zero
    let storedOffset = configuration.isPanEnabled ? viewport.offset : .zero
    return BehaviorTreeCanvasTransform(
      scale: fitScale * zoom,
      offset: CGSize(
        width: storedOffset.width + drag.width,
        height: storedOffset.height + drag.height
      )
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

  private func clampedZoom(_ proposed: CGFloat) -> CGFloat {
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
    _ edge: BehaviorTreeDiagramEdge,
    frontier: Set<BehaviorNodeID>,
    in context: inout GraphicsContext
  ) {
    var path = Path()
    path.move(to: edge.start)
    let rolePosition: CGPoint
    switch diagram.layout.direction {
    case .topDown:
      let distance = edge.end.y - edge.start.y
      path.addCurve(
        to: edge.end,
        control1: CGPoint(
          x: edge.start.x,
          y: edge.start.y + distance * 0.45
        ),
        control2: CGPoint(
          x: edge.end.x,
          y: edge.end.y - distance * 0.45
        )
      )
      rolePosition = CGPoint(
        x: (edge.start.x + edge.end.x) / 2,
        y: (edge.start.y + edge.end.y) / 2 - 7
      )
    case .leftToRight:
      let distance = edge.end.x - edge.start.x
      path.addCurve(
        to: edge.end,
        control1: CGPoint(
          x: edge.start.x + distance * 0.45,
          y: edge.start.y
        ),
        control2: CGPoint(
          x: edge.end.x - distance * 0.45,
          y: edge.end.y
        )
      )
      rolePosition = CGPoint(
        x: (edge.start.x + edge.end.x) / 2,
        y: (edge.start.y + edge.end.y) / 2 - 8
      )
    }
    guard let childIndex = diagram.nodeIndexByID[edge.childID] else { return }
    for status in BehaviorTreeCanvasAnimation.statuses {
      let weight = statusWeight(status, nodeIndex: childIndex)
      guard weight > 0.001 else { continue }
      let color =
        status == .idle
        ? theme.edgeColor
        : theme.nodeStyle(for: status).borderColor
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
        layer.opacity = weight
        layer.stroke(
          path,
          with: .color(color),
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: status == .skipped || status == .cancelled ? [6, 4] : []
          )
        )
      }
    }
    guard configuration.details.contains(.edgeRoles),
      let role = childRoleLabel(edge.childRole)
    else { return }
    var label = context.resolve(Text(verbatim: role).font(.caption2))
    label.shading = .color(theme.edgeTextColor)
    context.draw(
      label,
      at: rolePosition,
      anchor: .center
    )
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
    let style = theme.nodeStyle(for: status)
    let path = Path(roundedRect: node.frame, cornerRadius: 12)
    let isReactive = node.attributes["memory"] == .string("reactive")
    for candidate in BehaviorTreeCanvasAnimation.statuses {
      let weight = statusWeight(candidate, nodeIndex: nodeIndex)
      guard weight > 0.001 else { continue }
      let candidateStyle = theme.nodeStyle(for: candidate)
      let lineWidth =
        candidate == .running
        ? (frontier.contains(node.id)
          ? theme.frontierLineWidth : theme.runningLineWidth)
        : 1
      let isDashed = candidate == .skipped || candidate == .cancelled || isReactive
      context.drawLayer { layer in
        layer.opacity = weight
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
      parts.append(state.status.rawValue.capitalized)
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
      Text(verbatim: abbreviated(node.label, limit: 30))
        .font(.caption.weight(.semibold))
    )
    label.shading = .color(style.textColor)
    context.draw(
      label,
      in: CGRect(
        x: textX,
        y: node.frame.minY + 10,
        width: textWidth,
        height: 20
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
        y: node.frame.minY + 34,
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
      badge.shading = .color(theme.nodeStyle(for: status).borderColor)
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
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.plain)
    .controlSize(.small)
    .padding(4)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
  }

  private func zoomOut() {
    viewport.zoom = max(configuration.minimumZoom, viewport.zoom / 1.25)
  }

  private func reset() {
    viewport = BehaviorTreeViewport()
  }

  private func zoomIn() {
    viewport.zoom = min(configuration.maximumZoom, viewport.zoom * 1.25)
  }
}

private struct BehaviorTreeLegend: View {
  let theme: BehaviorTreeViewTheme

  var body: some View {
    HStack(spacing: 8) {
      legendItem("Running", status: .running)
      legendItem("Succeeded", status: .succeeded)
      legendItem("Failed", status: .failed)
      legendItem("Skipped", status: .skipped)
      legendItem("Cancelled", status: .cancelled)
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
    status: BehaviorVisualizationStatus
  ) -> some View {
    HStack(spacing: 3) {
      Circle()
        .fill(theme.nodeStyle(for: status).borderColor)
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
    theme.nodeStyle(for: status).borderColor
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

private func childRoleLabel(_ role: BehaviorChildRole) -> String? {
  switch role {
  case .root, .child, .wrapped: nil
  case .condition: "condition"
  case .thenBranch: "then"
  case .elseBranch: "else"
  case .body(let index): "body \(index + 1)"
  case .onSuccess: "on success"
  case .onFailure: "on failure"
  case .onCancel: "on cancel"
  case .onExit: "on exit"
  }
}
