actor BehaviorInvalidationSource {
  private var generation: UInt64 = 0
  private var waiters: [UInt64: CheckedContinuation<UInt64, Never>] = [:]

  func currentGeneration() -> UInt64 {
    generation
  }

  func invalidate() {
    generation &+= 1
    let continuations = waiters.values
    waiters.removeAll(keepingCapacity: true)
    for continuation in continuations {
      continuation.resume(returning: generation)
    }
  }

  func waitForInvalidation(after observedGeneration: UInt64) async throws -> UInt64 {
    if generation != observedGeneration { return generation }
    let waiterID = UInt64.random(in: .min ... .max)
    return try await withTaskCancellationHandler {
      let nextGeneration = await withCheckedContinuation { continuation in
        if generation != observedGeneration {
          continuation.resume(returning: generation)
        } else {
          waiters[waiterID] = continuation
        }
      }
      try Task.checkCancellation()
      return nextGeneration
    } onCancel: {
      Task { await self.cancelWaiter(waiterID) }
    }
  }

  private func cancelWaiter(_ waiterID: UInt64) {
    waiters.removeValue(forKey: waiterID)?.resume(returning: generation)
  }
}

enum BehaviorRuntimeInvalidation {
  @TaskLocal static var source: BehaviorInvalidationSource?
}
