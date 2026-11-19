import Foundation

enum CLIInstaller {
    static let bin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

    @discardableResult
    static func install(_ launcher: URL, in directory: URL = bin) throws -> URL {
        let files = FileManager.default
        let destination = directory.appendingPathComponent("unt")
        guard files.isExecutableFile(atPath: launcher.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: launcher.path])
        }
        if let link = try? files.destinationOfSymbolicLink(atPath: destination.path) {
            if URL(fileURLWithPath: link, relativeTo: directory).standardizedFileURL == launcher.standardizedFileURL {
                return destination
            }
            throw conflict(at: destination)
        }
        if files.fileExists(atPath: destination.path) { throw conflict(at: destination) }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.createSymbolicLink(at: destination, withDestinationURL: launcher)
        } catch where ExternalFileWriter.isPermissionDenied(error) {
            try AdministratorScript.run(scriptSource(launcher: launcher, directory: directory),
                failure: "Couldn’t install unt at \(destination.path).")
        }
        return destination
    }

    private static func conflict(at destination: URL) -> NSError {
        NSError(domain: "untitled", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "\(destination.path) already exists. Move the existing item aside before installing unt."])
    }

    static func scriptSource(launcher: URL, directory: URL) -> String {
        let parent = "quoted form of \(AdministratorScript.literal(directory.path))"
        let source = "quoted form of \(AdministratorScript.literal(launcher.path))"
        // Give ln the parent directory so its exclusive creation also rejects a directory named unt.
        let command = "\"/bin/mkdir -p \" & \(parent) & \" && /bin/ln -sh \" & \(source) & \" \" & \(parent)"
        return AdministratorScript.source(command: command, prompt: "untitled wants to install the unt command in \(directory.path).")
    }
}
