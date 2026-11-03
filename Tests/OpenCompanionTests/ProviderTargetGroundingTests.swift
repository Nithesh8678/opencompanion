import Foundation
import Testing

@testable import OpenCompanion

struct ProviderTargetGroundingTests {
  @Test func candidateOnlyTargetCanBeDecodedWithoutFabricatedCoordinates() throws {
    let target = try decode(
      #"{"candidateID":"current-frame-control","instruction":"Click New task.","advanceOn":"click"}"#
    )
    #expect(target.candidateID == "current-frame-control")
    #expect(target.width == 0 && target.height == 0)
    #expect(target.instruction == "Click New task.")
  }

  @Test func legacyCoordinateTargetsRetainGeometryAndRequireAllBounds() throws {
    let target = try decode(
      #"{"x":0.2,"y":0.3,"width":0.04,"height":0.05,"instruction":"Click the icon."}"#)
    #expect(target.candidateID == nil)
    #expect(target.x == 0.2 && target.y == 0.3)
    #expect(target.width == 0.04 && target.height == 0.05)
    #expect(throws: (any Error).self) {
      try decode(#"{"instruction":"Click the icon."}"#)
    }
  }

  @Test func explicitNullCandidateDoesNotAuthorizeOmittedCoordinates() {
    #expect(throws: (any Error).self) {
      try decode(#"{"candidateID":null,"instruction":"Click the icon."}"#)
    }
  }

  private func decode(_ json: String) throws -> ProviderTarget {
    try JSONDecoder().decode(ProviderTarget.self, from: Data(json.utf8))
  }
}
