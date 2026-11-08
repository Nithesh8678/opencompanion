import AppKit
import SceneKit

/// Small retained studio rig. No textures, network assets, model-authored
/// shaders, physics, or per-frame light allocation are needed for an explanation.
@MainActor enum SpatialPresentationStyle {
  static func configure(_ view: SCNView, camera: SCNNode) {
    view.autoenablesDefaultLighting = false
    view.antialiasingMode = .multisampling4X
    view.preferredFramesPerSecond = 60
    view.rendersContinuously = false
    guard let lens = camera.camera else { return }
    lens.wantsHDR = true
    lens.wantsExposureAdaptation = false
    lens.exposureOffset = 0
    lens.bloomIntensity = 0
    // A modest local contact cue makes overlapping components distinguishable.
    // Keep it bounded to this compact viewport; no shadow-map render passes.
    lens.screenSpaceAmbientOcclusionIntensity = 0.35
    lens.screenSpaceAmbientOcclusionRadius = 0.18
    lens.screenSpaceAmbientOcclusionBias = 0.015
    let ambient = SCNNode()
    ambient.name = "presentation.ambient"
    ambient.light = SCNLight()
    ambient.light?.type = .ambient
    ambient.light?.intensity = 300
    ambient.light?.color = NSColor(white: 0.92, alpha: 1)
    camera.addChildNode(ambient)
    // Lights travel with the view so rear/underside inspection remains legible.
    for (name, position, intensity, color) in [
      ("key", SCNVector3(-3, 4, 4), CGFloat(950), NSColor(white: 1, alpha: 1)),
      ("fill", SCNVector3(4, 1, 2), CGFloat(450), NSColor(sceneHex: "#B9D8FF")),
      ("rim", SCNVector3(1, 3, -4), CGFloat(1_100), NSColor(white: 1, alpha: 1)),
    ] {
      let node = SCNNode()
      node.name = "presentation." + name
      node.position = position
      node.look(at: SCNVector3Zero)
      node.light = SCNLight()
      node.light?.type = .directional
      node.light?.intensity = intensity
      node.light?.color = color
      node.light?.castsShadow = false
      camera.addChildNode(node)
    }
  }

  static func material(color: NSColor) -> SCNMaterial {
    let material = SCNMaterial()
    material.diffuse.contents = color
    material.lightingModel = .physicallyBased
    material.metalness.contents = 0.08
    material.roughness.contents = 0.42
    material.isDoubleSided = false
    return material
  }
}
