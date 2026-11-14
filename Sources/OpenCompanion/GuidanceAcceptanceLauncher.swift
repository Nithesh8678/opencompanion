import Darwin
import Foundation

/// Explicit developer action. Only starts the existing isolated public-fixture
/// helper; that helper still owns every permission, capture and input guard.
enum GuidanceAcceptanceLauncher {
  enum Mode: String, CaseIterable, Sendable {
    case activeWorkflow, observation, browser, textedit, calculator

    /// Fixed helpers only. The generated output path is one literal argument,
    /// never shell input, a forwarded model prompt or an executable override.
    func arguments(output: URL) -> [String] {
      switch self {
      case .activeWorkflow: ["--guidance-active-workflow-acceptance", output.path]
      case .observation: ["--guidance-observation-acceptance", output.path]
      case .browser, .textedit, .calculator:
        ["--guidance-public-app-acceptance", output.path, rawValue]
      }
    }
  }

  struct Work: Sendable {
    var busy = false
    var listening = false
    var pendingSpeech = false
    var explanationVisible = false
    var hasDraft = false
  }

  enum Refusal: String, Error, Equatable, LocalizedError {
    case activeWork, noncanonicalApp, executableUnavailable, privateOutputUnavailable
    var errorDescription: String? {
      switch self {
      case .activeWork:
        "Finish the current work and save or clear your draft before this developer check."
      case .noncanonicalApp: "Run this check from /Applications/OpenCompanion.app."
      case .executableUnavailable: "The installed app executable is unavailable."
      case .privateOutputUnavailable: "A private diagnostic output could not be created."
      }
    }
  }

  static func validate(
    bundlePath: String, resolvedBundlePath: String,
    executablePath: String, resolvedExecutablePath: String,
    bundleID: String?, work: Work
  ) throws {
    guard !work.busy, !work.listening, !work.pendingSpeech,
      !work.explanationVisible, !work.hasDraft
    else { throw Refusal.activeWork }
    let canonical = "/Applications/OpenCompanion.app"
    let executable = canonical + "/Contents/MacOS/OpenCompanion"
    guard bundlePath == canonical, resolvedBundlePath == canonical,
      executablePath == executable, resolvedExecutablePath == executable,
      bundleID == "org.opencompanion.mac"
    else { throw Refusal.noncanonicalApp }
  }

  @MainActor static func launch(work: Work, mode: Mode = .activeWorkflow) throws -> Process {
    let bundle = Bundle.main
    guard let executable = bundle.executableURL else { throw Refusal.executableUnavailable }
    try validate(
      bundlePath: bundle.bundleURL.standardizedFileURL.path,
      resolvedBundlePath: bundle.bundleURL.resolvingSymlinksInPath().path,
      executablePath: executable.standardizedFileURL.path,
      resolvedExecutablePath: executable.resolvingSymlinksInPath().path,
      bundleID: bundle.bundleIdentifier, work: work)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw Refusal.executableUnavailable
    }
    let template = FileManager.default.temporaryDirectory
      .appendingPathComponent("OpenCompanion-Guidance-Task-XXXXXX").path
    var bytes = Array(template.utf8CString)
    guard mkdtemp(&bytes) != nil else { throw Refusal.privateOutputUnavailable }
    let output = URL(fileURLWithPath: String(cString: bytes), isDirectory: true)
    let log = output.appendingPathComponent("run.log")
    let descriptor = Darwin.open(log.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw Refusal.privateOutputUnavailable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    let revision = bundle.object(forInfoDictionaryKey: "OpenCompanionSourceRevision") as? String
    let arguments = mode.arguments(output: output)
    var manifest: [String: Any] = [
      "sourceRevision": String((revision ?? "unknown").prefix(128)),
      "bundlePath": bundle.bundleURL.path, "executablePath": executable.path,
      "parentPID": ProcessInfo.processInfo.processIdentifier,
      "mode": mode.rawValue, "helperFlag": arguments[0], "status": "prepared",
      "taskComplete": false, "automaticDesktopActions": false,
      "launchMethod": "Explicit normal-app developer menu; same installed executable",
    ]
    let manifestURL = output.appendingPathComponent("launch-manifest.json")
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      .write(to: manifestURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = bundle.bundleURL
    process.standardOutput = handle
    process.standardError = handle
    do {
      try process.run()
    } catch {
      manifest["status"] = "launch-failed"
      if let data = try? JSONSerialization.data(
        withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: manifestURL, options: .atomic)
      }
      throw error
    }
    // No fallible operation after this point can leave the parent running as
    // though no child was started. Process start is not a guidance-task pass.
    manifest["status"] = "process-started"
    manifest["childPID"] = process.processIdentifier
    if let data = try? JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: manifestURL, options: .atomic)
    }
    return process
  }
}
