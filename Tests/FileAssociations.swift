import AppKit
import CoreServices
import UniformTypeIdentifiers

// Run in a desktop session after building: xcrun swift Tests/FileAssociations.swift build/untitled.app
// Registers this bundle without changing default apps. All fixtures use a disposable directory.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: xcrun swift Tests/FileAssociations.swift path/to/untitled.app\n", stderr)
    exit(2)
}
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let root = FileManager.default.temporaryDirectory.appendingPathComponent("untitled-associations-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
do {
    guard let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier,
          let types = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else {
        throw NSError(domain: "FileAssociations", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Build the app before checking its registrations."])
    }
    let extensions = types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
    guard !extensions.isEmpty else {
        throw NSError(domain: "FileAssociations", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No extension registrations found in the built app."])
    }
    let status = LSRegisterURL(app as CFURL, true)
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var failures: [String] = []
    for ext in extensions {
        let url = root.appendingPathComponent("example.\(ext)")
        let text = ext == "plist" ? "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>" : "{\"check\":true}"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if !apps.contains(where: { Bundle(url: $0)?.bundleIdentifier == identifier }) {
            failures.append("\(ext): \(UTType(filenameExtension: ext)?.identifier ?? "unknown")")
        }
    }
    print("Finder registrations: \(extensions.count - failures.count)/\(extensions.count) extensions supported")
    for failure in failures { print("FAIL \(failure)") }
    if !failures.isEmpty { exit(1) }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
