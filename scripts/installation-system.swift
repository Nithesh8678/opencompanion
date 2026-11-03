import AppKit
import Foundation

// The coordinator constrains Trash candidates to known installation/build paths.
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "running":
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "org.opencompanion.mac"
                || $0.executableURL?.lastPathComponent == "OpenCompanion"
        }
        let records = applications.map {
            ["pid": Int($0.processIdentifier), "path": $0.bundleURL?.path ?? "unknown"] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    case "trash":
        guard arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
            info["CFBundleIdentifier"] as? String == "org.opencompanion.mac"
        else { throw CocoaError(.fileReadCorruptFile) }
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        print(destination?.path ?? "Moved to Trash")
    default:
        throw CocoaError(.fileReadInvalidFileName)
    }
} catch {
    FileHandle.standardError.write(Data("Installer system helper: \(error.localizedDescription)\n".utf8))
    exit(1)
}
