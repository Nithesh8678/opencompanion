import Foundation

/// Explicit offline examples. Model-authored content uses the same scene and transaction types.
public enum BuiltInLessons {
    public static func motor() throws -> SceneDocument {
        guard let url = Bundle.module.url(forResource: "original-motor-scene", withExtension: "json") else { throw CoreError.invalidDocument("missing bundled motor fixture") }
        return try OriginalSceneImporter.importDocument(data: Data(contentsOf: url))
    }
    public static func lever() -> SceneDocument {
        SceneDocument(id: "built-in-lever", title: "A little force, a longer distance", nodes: [
            .init(id: "title", kind: .text, x: 50, y: 40, width: 900, height: 50, text: "Why a longer lever feels easier", color: "#213C32", fontSize: 30),
            .init(id: "subtitle", kind: .text, x: 50, y: 100, width: 900, height: 40, text: "A simple, ideal lever • Built-in example", color: "#65776B", fontSize: 17),
            .init(id: "ground", kind: .line, color: "#B8C3B8", points: [.init(x: 100, y: 470), .init(x: 900, y: 470)]),
            .init(id: "fulcrum", kind: .path, color: "#476452", fill: "#DBE6D6", points: [.init(x: 640, y: 390), .init(x: 585, y: 470), .init(x: 695, y: 470), .init(x: 640, y: 390)]),
            .init(id: "beam", kind: .rectangle, x: 160, y: 363, width: 650, height: 24, color: "#7C5634", fill: "#CCA378", strokeWidth: 2),
            .init(id: "effort", kind: .arrow, color: "#2B7C64", strokeWidth: 5, points: [.init(x: 180, y: 200), .init(x: 180, y: 350)]),
            .init(id: "effort-label", kind: .text, x: 100, y: 160, width: 210, height: 35, text: "Effort: 50 N ↓", color: "#2B7C64", fontSize: 23),
            .init(id: "load", kind: .rectangle, x: 720, y: 282, width: 90, height: 80, text: "", color: "#A4503D", fill: "#E9BAA0"),
            .init(id: "load-label", kind: .text, x: 700, y: 220, width: 220, height: 40, text: "Load: 200 N", color: "#A4503D", fontSize: 22),
            .init(id: "long-arm", kind: .line, color: "#2B7C64", points: [.init(x: 180, y: 510), .init(x: 640, y: 510)]),
            .init(id: "long-arm-label", kind: .text, x: 310, y: 530, width: 240, height: 40, text: "Effort arm: 2 m", color: "#2B7C64", fontSize: 20),
            .init(id: "short-arm", kind: .line, color: "#A4503D", points: [.init(x: 640, y: 510), .init(x: 755, y: 510)]),
            .init(id: "short-arm-label", kind: .text, x: 640, y: 530, width: 300, height: 40, text: "Load arm: 0.5 m", color: "#A4503D", fontSize: 20),
            .init(id: "equation", kind: .text, x: 170, y: 595, width: 760, height: 40, text: "Balance: 50 N × 2 m = 200 N × 0.5 m", color: "#213C32", fontSize: 24)
        ], notes: "An ideal lever balances when clockwise and anticlockwise moments about its pivot are equal. A longer effort arm trades a greater movement distance for a smaller required force. Beam weight and friction are omitted.",
        citations: ["https://openstax.org/books/physics/pages/9-2-simple-machines"])
    }
    public static func circuit() -> SceneDocument {
        SceneDocument(id: "built-in-circuit", title: "One loop. A complete path.", nodes: [
            .init(id: "title", kind: .text, x: 55, y: 40, width: 900, height: 55, text: "Current needs a complete circuit", color: "#213C32", fontSize: 31),
            .init(id: "subtitle", kind: .text, x: 55, y: 105, width: 900, height: 35, text: "Conventional current flows from + to − outside the source.", color: "#65776B", fontSize: 19),
            .init(id: "left-wire", kind: .path, color: "#597165", strokeWidth: 4, points: [.init(x: 250, y: 330), .init(x: 150, y: 330), .init(x: 150, y: 500), .init(x: 820, y: 500), .init(x: 820, y: 330), .init(x: 720, y: 330)]),
            .init(id: "top-wire", kind: .path, color: "#597165", strokeWidth: 4, points: [.init(x: 280, y: 330), .init(x: 280, y: 220), .init(x: 660, y: 220), .init(x: 660, y: 280)]),
            .init(id: "battery-short", kind: .line, color: "#213C32", strokeWidth: 5, points: [.init(x: 250, y: 295), .init(x: 250, y: 365)]),
            .init(id: "battery-long", kind: .line, color: "#213C32", strokeWidth: 5, points: [.init(x: 280, y: 275), .init(x: 280, y: 385)]),
            .init(id: "source-label", kind: .text, x: 165, y: 405, width: 220, height: 40, text: "Source: 6 V", color: "#213C32", fontSize: 22),
            .init(id: "plus", kind: .text, x: 300, y: 290, width: 50, height: 40, text: "+", color: "#A4503D", fontSize: 28),
            .init(id: "minus", kind: .text, x: 210, y: 290, width: 40, height: 40, text: "−", color: "#2B7C64", fontSize: 28),
            .init(id: "bulb", kind: .ellipse, x: 610, y: 280, width: 110, height: 110, color: "#B58A32", fill: "#F4DEA4", strokeWidth: 3),
            .init(id: "filament", kind: .path, color: "#B58A32", strokeWidth: 3, subpaths: [[.init(x: 630, y: 300), .init(x: 700, y: 370)], [.init(x: 700, y: 300), .init(x: 630, y: 370)]]),
            .init(id: "bulb-label", kind: .text, x: 590, y: 410, width: 230, height: 40, text: "Lamp: 12 Ω", color: "#A57823", fontSize: 22),
            .init(id: "current", kind: .arrow, color: "#2B7C64", strokeWidth: 4, points: [.init(x: 400, y: 180), .init(x: 535, y: 180)]),
            .init(id: "current-label", kind: .text, x: 375, y: 140, width: 250, height: 35, text: "Current: 0.5 A", color: "#2B7C64", fontSize: 21),
            .init(id: "equation", kind: .text, x: 160, y: 570, width: 800, height: 50, text: "Ohm’s law: I = V / R = 6 / 12 = 0.5 A", color: "#213C32", fontSize: 26)
        ], notes: "Ideal source and a constant 12-ohm resistive lamp. Real incandescent lamps change resistance with temperature. Electrons drift opposite to conventional current; the source supplies energy to the circuit.",
        citations: ["https://openstax.org/books/university-physics-volume-2/pages/9-4-ohms-law"])
    }
}
