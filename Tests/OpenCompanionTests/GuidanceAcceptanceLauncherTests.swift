import Testing

@testable import OpenCompanion

struct GuidanceAcceptanceLauncherTests {
  private typealias Subject = GuidanceAcceptanceLauncher

  @Test func onlyTheCanonicalInstalledIdentityIsAdmitted() throws {
    try validate()
    for bundle in ["/tmp/OpenCompanion.app", "/Applications/OpenCompanion Copy.app"] {
      #expect(throws: Subject.Refusal.noncanonicalApp) { try validate(bundle: bundle) }
    }
    #expect(throws: Subject.Refusal.noncanonicalApp) {
      try validate(resolved: "/tmp/OpenCompanion.app")
    }
    #expect(throws: Subject.Refusal.noncanonicalApp) { try validate(bundleID: "org.other.app") }
    #expect(throws: Subject.Refusal.noncanonicalApp) {
      try validate(executable: "/bin/sh")
    }
    #expect(throws: Subject.Refusal.noncanonicalApp) {
      try validate(resolvedExecutable: "/tmp/OpenCompanion")
    }
  }

  @Test func activeWorkAndUnsentDraftsPreventRelaunch() {
    let states: [Subject.Work] = [
      .init(busy: true), .init(listening: true), .init(pendingSpeech: true),
      .init(explanationVisible: true), .init(hasDraft: true),
    ]
    for state in states {
      #expect(throws: Subject.Refusal.activeWork) { try validate(work: state) }
    }
  }

  private func validate(
    bundle: String = "/Applications/OpenCompanion.app",
    resolved: String = "/Applications/OpenCompanion.app",
    executable: String = "/Applications/OpenCompanion.app/Contents/MacOS/OpenCompanion",
    resolvedExecutable: String = "/Applications/OpenCompanion.app/Contents/MacOS/OpenCompanion",
    bundleID: String? = "org.opencompanion.mac", work: Subject.Work = .init()
  ) throws {
    try Subject.validate(
      bundlePath: bundle, resolvedBundlePath: resolved, executablePath: executable,
      resolvedExecutablePath: resolvedExecutable, bundleID: bundleID, work: work)
  }
}
