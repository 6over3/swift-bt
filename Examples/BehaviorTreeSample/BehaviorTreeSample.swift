import AppKit
import BehaviorTree
import BehaviorTreeUI
import Observation
import SwiftUI

private enum SampleAction: String, Sendable {
  case inspectMetadata
  case fetchPrimary
  case fetchReplicaA
  case fetchReplicaB
  case persistResult
}

private enum SampleCondition: String, Sendable {
  case inputAccepted
  case primaryAvailable
}

private actor SampleContext {
  let primaryAvailable: Bool
  let failFirstPrimaryAttempt: Bool
  private var primaryAttempts = 0

  init(primaryAvailable: Bool, failFirstPrimaryAttempt: Bool) {
    self.primaryAvailable = primaryAvailable
    self.failFirstPrimaryAttempt = failFirstPrimaryAttempt
  }

  func beginPrimaryAttempt() -> (attempt: Int, shouldFail: Bool) {
    primaryAttempts += 1
    return (
      primaryAttempts,
      failFirstPrimaryAttempt && primaryAttempts == 1
    )
  }
}

private struct SampleExecutor: BehaviorExecutor {
  func evaluate(
    _ condition: SampleCondition,
    in context: SampleContext
  ) async -> BehaviorConditionResult {
    switch condition {
    case .inputAccepted:
      return .satisfied(
        BehaviorDiagnostic(
          code: "sample.input-accepted",
          summary: "Input passed validation"
        )
      )

    case .primaryAvailable:
      return context.primaryAvailable
        ? .satisfied
        : .unsatisfied(
          code: "sample.primary-unavailable",
          summary: "Primary service is unavailable; trying replicas"
        )
    }
  }

  func perform(
    _ action: SampleAction,
    in context: SampleContext,
    reporting: BehaviorReporter
  ) async throws -> BehaviorActionResult {
    switch action {
    case .inspectMetadata:
      try await reportProgress(
        steps: 4,
        every: .milliseconds(160),
        message: "Inspecting metadata",
        reporting: reporting
      )
      await reporting.report(
        inspection: BehaviorInspection(
          summary: "PDF metadata parsed",
          values: [
            "contentType": "application/pdf",
            "pageCount": 8,
            "textLayer": true,
          ]
        )
      )
      return .succeeded

    case .fetchPrimary:
      let attempt = await context.beginPrimaryAttempt()
      try await reportProgress(
        steps: 5,
        every: .milliseconds(170),
        message: "Primary attempt \(attempt.attempt)",
        reporting: reporting
      )
      if attempt.shouldFail {
        return .failed(
          code: "sample.transient-primary-error",
          summary: "A transient error triggered the retry policy"
        )
      }
      return .succeeded

    case .fetchReplicaA:
      try await reportProgress(
        steps: 6,
        every: .milliseconds(180),
        message: "Reading replica A",
        reporting: reporting
      )
      return .succeeded

    case .fetchReplicaB:
      try await reportProgress(
        steps: 10,
        every: .milliseconds(180),
        message: "Reading replica B",
        reporting: reporting
      )
      return .succeeded

    case .persistResult:
      try await reportProgress(
        steps: 4,
        every: .milliseconds(140),
        message: "Committing result",
        reporting: reporting
      )
      return .succeeded
    }
  }

  private func reportProgress(
    steps: Int,
    every interval: Duration,
    message: String,
    reporting: BehaviorReporter
  ) async throws {
    for step in 1...steps {
      try await Task.sleep(for: interval)
      await reporting.report(
        completed: Int64(step),
        total: Int64(steps),
        message: message
      )
    }
  }
}

@MainActor
@Observable
private final class SampleModel {
  @ObservationIgnored let tree: BehaviorTree<SampleAction, SampleCondition>
  @ObservationIgnored let visualization: BehaviorVisualizationStore
  @ObservationIgnored private var execution: BehaviorTask?
  @ObservationIgnored private var resultTask: Task<Void, Never>?

  var primaryAvailable = true
  var failFirstPrimaryAttempt = true
  var status = "Ready"
  private var hasStarted = false

  init() {
    // Every value is constant and known-valid; a failure here is a sample bug.
    tree = try! BehaviorTree(name: "resilient-service-workflow") {
      Sequence("Process request") {
        Condition(.inputAccepted, named: "Validate input")
        Action(.inspectMetadata, named: "Inspect metadata")

        Selector("Resolve payload") {
          Sequence("Primary path") {
            Condition(.primaryAvailable, named: "Primary available?")
            Retry("Retry transient failure", maximumAttempts: 3, backoff: .milliseconds(300)) {
              Timeout(.seconds(3), named: "Primary deadline") {
                Action(.fetchPrimary, named: "Fetch from primary")
              }
            }
          }

          WhenAny("First healthy replica") {
            Action(.fetchReplicaA, named: "Fetch from replica A")
            Action(.fetchReplicaB, named: "Fetch from replica B")
          }
        }

        Action(.persistResult, named: "Persist result")
      }
    }
    visualization = tree.makeVisualization()
  }

  func startOnce() {
    guard !hasStarted else { return }
    hasStarted = true
    run()
  }

  func run() {
    execution?.cancel()
    resultTask?.cancel()
    visualization.reset()

    let context = SampleContext(
      primaryAvailable: primaryAvailable,
      failFirstPrimaryAttempt: failFirstPrimaryAttempt
    )
    let execution = tree.start(
      in: context,
      using: SampleExecutor(),
      observing: [visualization.observer]
    )
    self.execution = execution
    status = "Running"

    resultTask = Task { [weak self] in
      do {
        let result = try await execution.value
        guard !Task.isCancelled else { return }
        self?.status = result.outcome == .succeeded ? "Succeeded" : "Failed"
      } catch is CancellationError {
        guard !Task.isCancelled else { return }
        self?.status = "Cancelled"
      } catch {
        guard !Task.isCancelled else { return }
        self?.status = "Error: \(error)"
      }
    }
  }

  func cancel() {
    execution?.cancel()
  }
}

private struct SampleView: View {
  @State private var model = SampleModel()

  private let diagramLayout = BehaviorTreeDiagramLayout(
    direction: .leftToRight,
    nodeSize: CGSize(width: 210, height: 68),
    horizontalSpacing: 64,
    verticalSpacing: 18,
    contentPadding: 48
  )

  var body: some View {
    @Bindable var model = model

    VStack(spacing: 0) {
      HStack(spacing: 20) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Execution monitor")
            .font(.title3.weight(.semibold))
          Label(model.status, systemImage: statusSymbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
        }

        Spacer()

        HStack(spacing: 14) {
          Text("Next run")
            .font(.caption)
            .foregroundStyle(.secondary)
          Toggle("Primary", isOn: $model.primaryAvailable)
          Toggle("Retry demo", isOn: $model.failFirstPrimaryAttempt)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.65), in: .rect(cornerRadius: 10))

        Button {
          model.cancel()
        } label: {
          Label("Cancel", systemImage: "stop.fill")
        }
        .disabled(model.status != "Running")

        Button {
          model.run()
        } label: {
          Label("Run", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .background(.bar)

      BehaviorTreeView(
        visualization: model.visualization,
        layout: diagramLayout
      )
      .behaviorTreeLegendVisible(true)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 1_300, minHeight: 760)
    .task {
      model.startOnce()
    }
  }

  private var statusSymbol: String {
    switch model.status {
    case "Running": "circle.dotted"
    case "Succeeded": "checkmark.circle.fill"
    case "Failed": "xmark.circle.fill"
    case "Cancelled": "stop.circle.fill"
    default: "circle"
    }
  }

  private var statusColor: Color {
    switch model.status {
    case "Running": .blue
    case "Succeeded": .green
    case "Failed": .red
    case "Cancelled": .orange
    default: .secondary
    }
  }
}

private final class SampleAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    true
  }
}

@main
private struct BehaviorTreeSampleApp: App {
  @NSApplicationDelegateAdaptor(SampleAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup("swift-bt Live Execution") {
      SampleView()
    }
    .defaultSize(width: 1_440, height: 840)
  }
}
