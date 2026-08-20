/// Graphviz attributes used to draw one visualization state.
public struct BehaviorGraphvizNodeStyle: Codable, Hashable, Sendable {
  /// A Graphviz color name or custom color value for the node border.
  public var borderColor: String

  /// A Graphviz color name or custom color value for the node background.
  public var fillColor: String

  /// A Graphviz color name or custom color value for the node label.
  public var textColor: String

  /// A Graphviz node style such as `filled` or `filled,dashed`.
  public var style: String

  /// Creates the attributes for one visualization state.
  public init(
    borderColor: String,
    fillColor: String,
    textColor: String = "black",
    style: String = "filled"
  ) {
    self.borderColor = borderColor
    self.fillColor = fillColor
    self.textColor = textColor
    self.style = style
  }
}

/// Customizable Graphviz appearance for static and live behavior trees.
///
/// Color values are passed through as escaped Graphviz color strings. They may
/// use named colors, scheme-qualified names, or custom RGB, RGBA, HSV, and HSVA
/// values supported by the target Graphviz renderer.
public struct BehaviorGraphvizTheme: Codable, Hashable, Sendable {
  /// The graph canvas color.
  public var backgroundColor: String

  /// The color used for edges between nodes.
  public var edgeColor: String

  /// The color used for edge role labels.
  public var edgeTextColor: String

  /// The Graphviz font name used by nodes and edges.
  public var fontName: String

  /// Appearance of nodes that have not run.
  public var idle: BehaviorGraphvizNodeStyle

  /// Appearance of active nodes.
  public var running: BehaviorGraphvizNodeStyle

  /// Appearance of nodes that succeeded.
  public var succeeded: BehaviorGraphvizNodeStyle

  /// Appearance of nodes that failed.
  public var failed: BehaviorGraphvizNodeStyle

  /// Appearance of nodes omitted by precondition policy.
  public var skipped: BehaviorGraphvizNodeStyle

  /// Appearance of nodes abandoned through cancellation.
  public var cancelled: BehaviorGraphvizNodeStyle

  /// Border width for active nodes that contain active descendants.
  public var runningPenWidth: Double

  /// Border width for active frontier nodes currently doing or awaiting work.
  public var frontierPenWidth: Double

  /// The named-color theme used when no custom theme is supplied.
  public static let `default` = Self()

  /// Creates a Graphviz theme.
  public init(
    backgroundColor: String = "white",
    edgeColor: String = "slategray",
    edgeTextColor: String = "slategray",
    fontName: String = "Helvetica",
    idle: BehaviorGraphvizNodeStyle = .init(
      borderColor: "slategray",
      fillColor: "white"
    ),
    running: BehaviorGraphvizNodeStyle = .init(
      borderColor: "dodgerblue3",
      fillColor: "lightblue"
    ),
    succeeded: BehaviorGraphvizNodeStyle = .init(
      borderColor: "forestgreen",
      fillColor: "palegreen"
    ),
    failed: BehaviorGraphvizNodeStyle = .init(
      borderColor: "firebrick",
      fillColor: "mistyrose"
    ),
    skipped: BehaviorGraphvizNodeStyle = .init(
      borderColor: "darkgray",
      fillColor: "whitesmoke",
      textColor: "dimgray",
      style: "filled,dashed"
    ),
    cancelled: BehaviorGraphvizNodeStyle = .init(
      borderColor: "slategray",
      fillColor: "gainsboro",
      textColor: "dimgray",
      style: "filled,dashed"
    ),
    runningPenWidth: Double = 2,
    frontierPenWidth: Double = 3
  ) {
    self.backgroundColor = backgroundColor
    self.edgeColor = edgeColor
    self.edgeTextColor = edgeTextColor
    self.fontName = fontName
    self.idle = idle
    self.running = running
    self.succeeded = succeeded
    self.failed = failed
    self.skipped = skipped
    self.cancelled = cancelled
    self.runningPenWidth = runningPenWidth
    self.frontierPenWidth = frontierPenWidth
  }

  func nodeStyle(for status: BehaviorVisualizationStatus) -> BehaviorGraphvizNodeStyle {
    switch status {
    case .idle: idle
    case .running: running
    case .succeeded: succeeded
    case .failed: failed
    case .skipped: skipped
    case .cancelled: cancelled
    }
  }
}
