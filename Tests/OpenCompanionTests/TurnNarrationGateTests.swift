import Testing

@testable import OpenCompanion

struct TurnNarrationGateTests {
  private func check(_ text: String, gate: inout TurnNarrationGate, expected: Bool = true) {
    let admitted = gate.admit(text)
    #expect(admitted == expected)
  }
  @Test func duplicateNarrationIsSuppressedInEitherUnitOrder() {
    for first in ["Open your profile", "  OPEN your\nprofile "] {
      var gate = TurnNarrationGate()
      check(first, gate: &gate)
      check("Choose Settings", gate: &gate)
      check("Open your profile", gate: &gate, expected: false)
      check("choose settings", gate: &gate, expected: false)
    }
  }

  @Test func aNewTurnMayRepeatAnInstruction() {
    var gate = TurnNarrationGate()
    check("Continue", gate: &gate)
    check("Continue", gate: &gate, expected: false)
    gate.reset()
    check("Continue", gate: &gate)
  }

  @Test func inputAndHistoryAreBounded() {
    var gate = TurnNarrationGate()
    check(" \n\t", gate: &gate, expected: false)
    check(String(repeating: "x", count: 32_001), gate: &gate, expected: false)
    for index in 0..<128 { check("Step \(index)", gate: &gate) }
    check("Step 0", gate: &gate, expected: false)
    check("Step 128", gate: &gate)
    check("Step 0", gate: &gate)
  }
}
