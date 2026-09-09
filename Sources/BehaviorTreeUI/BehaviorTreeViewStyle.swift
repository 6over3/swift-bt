import BehaviorTree
import SwiftUI

/// Visual attributes used to draw one behavior-node state.
public struct BehaviorTreeViewNodeStyle: Sendable {
  public var borderColor: Color
  public var fillColor: Color
  public var textColor: Color

  /// Creates a native SwiftUI node style.
  public init(
    borderColor: Color,
    fillColor: Color,
    textColor: Color = .primary
  ) {
    self.borderColor = borderColor
    self.fillColor = fillColor
    self.textColor = textColor
  }
}

/// Native SwiftUI colors and line weights for a behavior-tree view.
public struct BehaviorTreeViewTheme: Sendable {
  public var backgroundColor: Color
  public var edgeColor: Color
  public var edgeTextColor: Color
  public var executionGroupBorderColor: Color
  public var executionGroupFillColor: Color
  public var executionGroupTextColor: Color
  public var idle: BehaviorTreeViewNodeStyle
  public var running: BehaviorTreeViewNodeStyle
  public var completed: BehaviorTreeViewNodeStyle
  public var noResult: BehaviorTreeViewNodeStyle
  public var succeeded: BehaviorTreeViewNodeStyle
  public var failed: BehaviorTreeViewNodeStyle
  public var skipped: BehaviorTreeViewNodeStyle
  public var cancelled: BehaviorTreeViewNodeStyle
  public var runningLineWidth: CGFloat
  public var frontierLineWidth: CGFloat

  /// The adaptive theme used when no custom theme is supplied.
  public static let `default` = Self()

  /// Creates a native behavior-tree theme.
  public init(
    backgroundColor: Color = .clear,
    edgeColor: Color = .secondary.opacity(0.28),
    edgeTextColor: Color = .secondary,
    executionGroupBorderColor: Color = .secondary.opacity(0.24),
    executionGroupFillColor: Color = .primary.opacity(0.018),
    executionGroupTextColor: Color = .secondary,
    idle: BehaviorTreeViewNodeStyle = .init(
      borderColor: .secondary.opacity(0.42),
      fillColor: .primary.opacity(0.045)
    ),
    running: BehaviorTreeViewNodeStyle = .init(
      borderColor: .blue,
      fillColor: .blue.opacity(0.11)
    ),
    completed: BehaviorTreeViewNodeStyle = .init(
      borderColor: .secondary.opacity(0.72),
      fillColor: .secondary.opacity(0.06)
    ),
    noResult: BehaviorTreeViewNodeStyle = .init(
      borderColor: .secondary.opacity(0.46),
      fillColor: .secondary.opacity(0.025),
      textColor: .secondary
    ),
    succeeded: BehaviorTreeViewNodeStyle = .init(
      borderColor: .green.opacity(0.72),
      fillColor: .green.opacity(0.065)
    ),
    failed: BehaviorTreeViewNodeStyle = .init(
      borderColor: .red,
      fillColor: .red.opacity(0.09)
    ),
    skipped: BehaviorTreeViewNodeStyle = .init(
      borderColor: .secondary.opacity(0.38),
      fillColor: .secondary.opacity(0.035),
      textColor: .secondary
    ),
    cancelled: BehaviorTreeViewNodeStyle = .init(
      borderColor: .orange.opacity(0.75),
      fillColor: .orange.opacity(0.07),
      textColor: .secondary
    ),
    runningLineWidth: CGFloat = 2,
    frontierLineWidth: CGFloat = 3
  ) {
    precondition(runningLineWidth > 0 && frontierLineWidth > 0)
    self.backgroundColor = backgroundColor
    self.edgeColor = edgeColor
    self.edgeTextColor = edgeTextColor
    self.executionGroupBorderColor = executionGroupBorderColor
    self.executionGroupFillColor = executionGroupFillColor
    self.executionGroupTextColor = executionGroupTextColor
    self.idle = idle
    self.running = running
    self.completed = completed
    self.noResult = noResult
    self.succeeded = succeeded
    self.failed = failed
    self.skipped = skipped
    self.cancelled = cancelled
    self.runningLineWidth = runningLineWidth
    self.frontierLineWidth = frontierLineWidth
  }

  func nodeStyle(
    for status: BehaviorVisualizationStatus
  ) -> BehaviorTreeViewNodeStyle {
    switch status {
    case .idle: idle
    case .running: running
    case .succeeded: succeeded
    case .failed: failed
    case .skipped: skipped
    case .cancelled: cancelled
    }
  }

  func nodeStyle(
    for status: BehaviorVisualizationStatus,
    inspectionOutcome: BehaviorInspectionOutcome?
  ) -> BehaviorTreeViewNodeStyle {
    guard status == .succeeded else { return nodeStyle(for: status) }
    switch inspectionOutcome {
    case .completed: return completed
    case .noResult: return noResult
    case .produced, nil: return succeeded
    }
  }
}

/// Optional details shown beneath a node label.
public struct BehaviorTreeNodeDetails: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8

  /// Creates a detail option set from its persisted bits.
  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let status = Self(rawValue: 1 << 0)
  public static let attempt = Self(rawValue: 1 << 1)
  public static let progress = Self(rawValue: 1 << 2)
  public static let diagnostic = Self(rawValue: 1 << 3)
  public static let edgeRoles = Self(rawValue: 1 << 4)
  public static let inspection = Self(rawValue: 1 << 5)

  /// The detail set used by default.
  public static let `default`: Self = [.status, .attempt, .progress]

  /// Every available node and edge detail.
  public static let all: Self = [
    .status, .attempt, .progress, .diagnostic, .edgeRoles, .inspection,
  ]
}

/// Interaction and rendering behavior inherited by a behavior-tree view.
public struct BehaviorTreeViewConfiguration: Sendable {
  public internal(set) var isPanEnabled: Bool
  public internal(set) var isZoomEnabled: Bool
  public internal(set) var areControlsVisible: Bool
  public internal(set) var isExecutionStatusVisible: Bool
  public internal(set) var isLegendVisible: Bool
  public internal(set) var isSelectionEnabled: Bool
  public internal(set) var isInspectorVisible: Bool
  public internal(set) var rendersAsynchronously: Bool
  public internal(set) var initialZoom: CGFloat
  public internal(set) var centersSelection: Bool
  public internal(set) var minimumZoom: CGFloat
  public internal(set) var maximumZoom: CGFloat
  public internal(set) var details: BehaviorTreeNodeDetails
  public internal(set) var highlightedNodeIDs: Set<BehaviorNodeID>?

  /// Creates behavior-tree view configuration.
  public init(
    isPanEnabled: Bool = true,
    isZoomEnabled: Bool = true,
    areControlsVisible: Bool = true,
    isExecutionStatusVisible: Bool = true,
    isLegendVisible: Bool = true,
    isSelectionEnabled: Bool = true,
    isInspectorVisible: Bool = true,
    rendersAsynchronously: Bool = true,
    initialZoom: CGFloat = 1,
    centersSelection: Bool = false,
    minimumZoom: CGFloat = 0.25,
    maximumZoom: CGFloat = 8,
    details: BehaviorTreeNodeDetails = .default,
    highlightedNodeIDs: Set<BehaviorNodeID>? = nil
  ) {
    precondition(
      minimumZoom > 0 && maximumZoom >= minimumZoom
        && initialZoom >= minimumZoom && initialZoom <= maximumZoom
    )
    self.isPanEnabled = isPanEnabled
    self.isZoomEnabled = isZoomEnabled
    self.areControlsVisible = areControlsVisible
    self.isExecutionStatusVisible = isExecutionStatusVisible
    self.isLegendVisible = isLegendVisible
    self.isSelectionEnabled = isSelectionEnabled
    self.isInspectorVisible = isInspectorVisible
    self.rendersAsynchronously = rendersAsynchronously
    self.initialZoom = initialZoom
    self.centersSelection = centersSelection
    self.minimumZoom = minimumZoom
    self.maximumZoom = maximumZoom
    self.details = details
    self.highlightedNodeIDs = highlightedNodeIDs
  }
}

extension EnvironmentValues {
  @Entry var behaviorTreeViewConfiguration = BehaviorTreeViewConfiguration()
  @Entry var behaviorTreeViewTheme = BehaviorTreeViewTheme.default
}

extension View {
  /// Enables or disables drag-to-pan interaction for behavior-tree descendants.
  public func behaviorTreePanEnabled(_ isEnabled: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.isPanEnabled = isEnabled
    }
  }

  /// Enables or disables pinch-to-zoom interaction for behavior-tree descendants.
  public func behaviorTreeZoomEnabled(_ isEnabled: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.isZoomEnabled = isEnabled
    }
  }

  /// Shows or hides the native zoom and reset controls.
  public func behaviorTreeControlsVisible(_ isVisible: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.areControlsVisible = isVisible
    }
  }

  /// Shows or hides the current execution status and event sequence.
  public func behaviorTreeExecutionStatusVisible(_ isVisible: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.isExecutionStatusVisible = isVisible
    }
  }

  /// Shows or hides the execution-state legend.
  public func behaviorTreeLegendVisible(_ isVisible: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.isLegendVisible = isVisible
    }
  }

  /// Enables or disables node selection.
  public func behaviorTreeSelectionEnabled(_ isEnabled: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.isSelectionEnabled = isEnabled
    }
  }

  /// Shows or hides the built-in full-detail inspector.
  public func behaviorTreeInspectorEnabled(_ isEnabled: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.isInspectorVisible = isEnabled
    }
  }

  /// Controls whether the Canvas may render away from the main thread.
  public func behaviorTreeRendersAsynchronously(_ isEnabled: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.rendersAsynchronously = isEnabled
    }
  }

  /// Sets the zoom used when a new diagram first appears.
  public func behaviorTreeInitialZoom(_ zoom: CGFloat) -> some View {
    precondition(zoom > 0)
    return transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.initialZoom = zoom
      $0.minimumZoom = min($0.minimumZoom, zoom)
      $0.maximumZoom = max($0.maximumZoom, zoom)
    }
  }

  /// Centers the viewport when the selected node changes.
  public func behaviorTreeCentersSelection(_ isEnabled: Bool) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.centersSelection = isEnabled
    }
  }

  /// Sets the user-controlled absolute diagram scale range.
  public func behaviorTreeZoomRange(
    minimum: CGFloat,
    maximum: CGFloat
  ) -> some View {
    precondition(minimum > 0 && maximum >= minimum)
    return transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.minimumZoom = minimum
      $0.maximumZoom = maximum
    }
  }

  /// Selects which runtime details appear in nodes and on edges.
  public func behaviorTreeNodeDetails(
    _ details: BehaviorTreeNodeDetails
  ) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.details = details
    }
  }

  /// Highlights matching nodes and visually recedes the remaining graph.
  ///
  /// Pass `nil` to disable filtering emphasis. An empty set deliberately
  /// communicates that the active search has no matches.
  public func behaviorTreeHighlightedNodes(
    _ nodeIDs: Set<BehaviorNodeID>?
  ) -> some View {
    transformEnvironment(\.behaviorTreeViewConfiguration) {
      $0.highlightedNodeIDs = nodeIDs
    }
  }

  /// Applies a native SwiftUI behavior-tree theme.
  public func behaviorTreeTheme(_ theme: BehaviorTreeViewTheme) -> some View {
    environment(\.behaviorTreeViewTheme, theme)
  }
}
