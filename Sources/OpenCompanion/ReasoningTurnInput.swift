import CompanionCore
import Foundation

/// Immutable input assembled by the host before provider dispatch. Injected
/// responders exercise the same admission callbacks without opening a transport.
struct ReasoningTurnInput: Sendable {
  let messages: [ChatLine]
  let context: String
  let image: Data?
  let scene: SceneDocument?
  let responsePolicy: ResponsePolicy
}

typealias ReasoningTurnStream =
  @MainActor (
    ReasoningTurnInput,
    @escaping @Sendable (ProviderUnit) async throws -> Void,
    @escaping @Sendable (ProviderTextPreview) async throws -> Void
  ) async throws -> Void
