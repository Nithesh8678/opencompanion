/// The host owns the visual style of advancing controls. This is presentation
/// only: unsupported shapes and invalid geometry still reach normal validation.
enum GuidanceTargetPresentation {
  static func styled(_ target: ProviderTarget) -> ProviderTarget {
    guard target.advanceOn == "click" else { return target }
    switch target.shape {
    case nil, "ellipse", "roundedRectangle":
      var styled = target
      styled.shape = "ellipse"
      return styled
    default:
      return target
    }
  }
}
