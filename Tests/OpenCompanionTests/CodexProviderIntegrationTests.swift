import Foundation
import Testing

@testable import OpenCompanion

struct CodexProviderIntegrationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCOMPANION_LIVE_CODEX_TEST"] == "1"))
  func managedChatGPTSubscriptionProducesGenericLessonsAndRetainedEdits() async throws {
    let environment = ProcessInfo.processInfo.environment
    let executable =
      environment["OPENCOMPANION_CODEX_EXECUTABLE"]
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")
      .path
    try await CodexIntegrationSmoke.run(
      executable: executable, model: environment["OPENCOMPANION_CODEX_MODEL"] ?? ""
    ) { message in
      print("Codex integration: \(message)")
    }
  }
}
