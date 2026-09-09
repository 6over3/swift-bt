/// A terminal behavior-tree decision.
public enum BehaviorOutcome: String, Codable, Hashable, Sendable {
  case succeeded
  case failed
}

/// The lifecycle state of a node in a host-driven execution.
public enum BehaviorStatus: String, Codable, Hashable, Sendable {
  case idle
  case running
  case succeeded
  case failed
  case cancelled

  /// The terminal outcome represented by this state, if any.
  public var outcome: BehaviorOutcome? {
    switch self {
    case .succeeded: .succeeded
    case .failed: .failed
    case .idle, .running, .cancelled: nil
    }
  }
}

/// A metadata value safe to serialize and send to observability backends.
public enum BehaviorMetadataValue: Codable, Hashable, Sendable {
  case boolean(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
}

extension BehaviorMetadataValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

extension BehaviorMetadataValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension BehaviorMetadataValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .double(value) }
}

extension BehaviorMetadataValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension BehaviorMetadataValue: CustomStringConvertible {
  /// A concise representation suitable for logs and inspection interfaces.
  public var description: String {
    switch self {
    case .boolean(let value): String(value)
    case .integer(let value): String(value)
    case .double(let value): String(value)
    case .string(let value): value
    }
  }
}

/// A stable application-defined reason that can be attached to a decision.
public protocol BehaviorReason: RawRepresentable, Sendable where RawValue == String {}

/// Structured context explaining an expected behavior-tree decision.
public struct BehaviorDiagnostic: Codable, Hashable, Sendable {
  public let code: String
  public let summary: String?
  public let attributes: [String: BehaviorMetadataValue]

  /// Creates a diagnostic with a stable code and operationally safe details.
  public init(
    code: String,
    summary: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) {
    self.code = code
    self.summary = summary
    self.attributes = attributes
  }

  /// Creates a diagnostic from a strongly typed application reason.
  public init<Reason: BehaviorReason>(
    reason: Reason,
    summary: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) {
    self.init(
      code: reason.rawValue,
      summary: summary,
      attributes: attributes
    )
  }
}

/// The result of evaluating a condition leaf.
public enum BehaviorConditionResult: Codable, Hashable, Sendable {
  case satisfied(BehaviorDiagnostic?)
  case unsatisfied(BehaviorDiagnostic?)

  /// A satisfied result without additional diagnostics.
  public static var satisfied: Self { .satisfied(nil) }

  /// An unsatisfied result without additional diagnostics.
  public static var unsatisfied: Self { .unsatisfied(nil) }

  /// Whether the condition accepted the current context.
  public var isSatisfied: Bool {
    if case .satisfied = self { true } else { false }
  }

  /// The diagnostic supplied by the executor, if any.
  public var diagnostic: BehaviorDiagnostic? {
    switch self {
    case .satisfied(let diagnostic), .unsatisfied(let diagnostic): diagnostic
    }
  }

  /// Creates an unsatisfied result with a stable reason.
  public static func unsatisfied(
    code: String,
    summary: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) -> Self {
    .unsatisfied(
      BehaviorDiagnostic(
        code: code,
        summary: summary,
        attributes: attributes
      )
    )
  }

  /// Creates a satisfied result with optional explanatory metadata.
  public static func satisfied(
    code: String,
    summary: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) -> Self {
    .satisfied(
      BehaviorDiagnostic(
        code: code,
        summary: summary,
        attributes: attributes
      )
    )
  }
}

/// An action's current lifecycle state and its optional explanation.
public struct BehaviorActionResult: Codable, Hashable, Sendable {
  /// The action's current lifecycle state.
  ///
  /// `running` is meaningful for host-driven executions. It lets an action
  /// publish durable work and yield until an external event advances the tree
  /// again. Continuously-run trees reject a running action because they have no
  /// application-owned suspension boundary.
  public let status: BehaviorStatus
  public let diagnostic: BehaviorDiagnostic?

  /// A successful action without additional diagnostics.
  public static let succeeded = Self(status: .succeeded)

  /// A failed action without additional diagnostics.
  public static let failed = Self(status: .failed)

  /// An action that has started but is waiting for application-owned work.
  public static let running = Self(status: .running)

  /// The terminal outcome, or `nil` while the action is running.
  public var outcome: BehaviorOutcome? { status.outcome }

  /// Creates an action result.
  public init(
    outcome: BehaviorOutcome,
    diagnostic: BehaviorDiagnostic? = nil
  ) {
    status = outcome == .succeeded ? .succeeded : .failed
    self.diagnostic = diagnostic
  }

  /// Creates an action result from one valid action lifecycle state.
  public init(
    status: BehaviorStatus,
    diagnostic: BehaviorDiagnostic? = nil
  ) {
    precondition(
      status == .running || status == .succeeded || status == .failed,
      "An action result must be running, succeeded, or failed"
    )
    self.status = status
    self.diagnostic = diagnostic
  }

  /// Creates a failed action result with a stable reason.
  public static func failed(
    code: String,
    summary: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) -> Self {
    Self(
      status: .failed,
      diagnostic: BehaviorDiagnostic(
        code: code,
        summary: summary,
        attributes: attributes
      )
    )
  }

  /// Creates a successful action result with a stable explanation.
  public static func succeeded(
    code: String,
    summary: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) -> Self {
    Self(
      status: .succeeded,
      diagnostic: BehaviorDiagnostic(
        code: code,
        summary: summary,
        attributes: attributes
      )
    )
  }

  /// Creates a running result with a stable suspension reason.
  public static func running(
    code: String,
    summary: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) -> Self {
    Self(
      status: .running,
      diagnostic: BehaviorDiagnostic(
        code: code,
        summary: summary,
        attributes: attributes
      )
    )
  }
}

/// A nonnegative, serializable duration used by tree definitions.
public struct BehaviorDuration: Codable, Hashable, Sendable, Comparable {
  public let nanoseconds: Int64

  /// Creates a duration from a nanosecond count.
  public init(nanoseconds: Int64) {
    self.nanoseconds = nanoseconds
  }

  /// Creates a definition duration from Swift's `Duration` value.
  public init(_ duration: Duration) {
    let components = duration.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let subsecond = components.attoseconds / 1_000_000_000
    let total = seconds.partialValue.addingReportingOverflow(subsecond)
    nanoseconds =
      seconds.overflow || total.overflow
      ? (components.seconds < 0 ? .min : .max)
      : total.partialValue
  }

  /// The equivalent Swift `Duration` value.
  public var duration: Duration { .nanoseconds(nanoseconds) }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.nanoseconds < rhs.nanoseconds
  }
}
