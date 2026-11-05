import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

/// Exercise the actual submission boundary, cancelling before the queued task
/// can reach a provider. Presentation identity is supplied by the native host.
@Suite @MainActor struct AppModelSceneVisibilityTests {
  @Test func visibleMatchingSurfaceAuthorizesOnlyTheRetainedDocument() throws {
    let model = fixture()
    defer { model.stop() }
    let original = try #require(model.scene)
    model.isScenePresentationVisible = { $0 == original.id }
    model.input = "Change the selected label in this notebook"
    model.send()
    #expect(model.responsePolicy.includesExistingNotebook)
    let label = try #require(original.nodes.first { $0.kind == .text })
    let unit = try JSONDecoder().decode(
      ProviderUnit.self,
      from: JSONSerialization.data(withJSONObject: [
        "type": "scene", "baseDocumentRevision": original.revision,
        "operations": [["op": "node.patch", "id": label.id, "fields": ["text": "Updated label"]]],
      ]))
    try model.accept(unit, generation: model.taskGeneration, expectedEvidence: nil)
    #expect(model.scene?.id == original.id)
    #expect(model.scene?.nodes.first { $0.id == label.id }?.text == "Updated label")
    #expect(
      model.scene?.nodes.filter { $0.id != label.id } == original.nodes.filter { $0.id != label.id }
    )
  }

  @Test(arguments: [false, true])
  func hiddenOrWrongDocumentSurfaceDoesNotGrantRetainedEditAuthority(_ differentDocument: Bool) {
    let model = fixture()
    defer { model.stop() }
    let original = model.scene
    model.isScenePresentationVisible = { id in differentDocument && id == "another-document" }
    model.input = "Change the selected label in this notebook"
    model.send()
    #expect(!model.responsePolicy.includesExistingNotebook)
    #expect(model.scene == original)
  }

  @Test func missingPresentationHostFailsClosedEvenWhenSidebarSaysNotebook() {
    let model = fixture()
    defer { model.stop() }
    model.input = "Change the selected label in this notebook"
    model.send()
    #expect(!model.responsePolicy.includesExistingNotebook)
  }

  @Test func newChatDoesNotInheritAnEditorsContext() {
    let model = fixture()
    defer { model.stop() }
    let original = model.scene
    model.isScenePresentationVisible = { $0 == original?.id }
    model.newConversation()
    model.input = "Change the selected label in this notebook"
    model.send()
    #expect(!model.responsePolicy.includesExistingNotebook)
    #expect(model.scene == original)
  }

  private func fixture() -> AppModel {
    let model = AppModel(acceptanceMode: true)
    model.configuration.speechEnabled = false
    model.scene = BuiltInLessons.lever()
    model.section = "Notebook"
    return model
  }
}
