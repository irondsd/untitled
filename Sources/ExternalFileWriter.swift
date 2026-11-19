import Foundation

/// Writes notes back to files on disk. Files the user may not write, such as /etc/hosts,
/// are saved through the system administrator password prompt instead of failing.
enum ExternalFileWriter {
    static func write(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch where isPermissionDenied(error) {
            try writeAsAdministrator(text, to: url)
        }
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteNoPermission.rawValue { return true }
            if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Copies a private temporary file over the target as root. Overwriting in place keeps the
    /// target's owner and permissions, but unlike ordinary saves it is not an atomic replacement.
    static func writeAsAdministrator(_ text: String, to url: URL) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("untitled-save-\(UUID().uuidString)")
        try text.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        try AdministratorScript.run(scriptSource(copying: temp.path, to: url.path),
            failure: "Couldn’t save “\(url.lastPathComponent)” as administrator.")
    }

    static func scriptSource(copying source: String, to destination: String) -> String {
        let prompt = "untitled wants to save “\((destination as NSString).lastPathComponent)”."
        let command = "\"/bin/cat \" & quoted form of \(AdministratorScript.literal(source))"
            + " & \" > \" & quoted form of \(AdministratorScript.literal(destination))"
        return AdministratorScript.source(command: command, prompt: prompt)
    }
}

enum AdministratorScript {
    static func run(_ source: String, failure: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "untitled", code: 2, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        if errorInfo[NSAppleScript.errorNumber] as? Int == -128 { throw CocoaError(.userCancelled) }
        let reason = errorInfo[NSAppleScript.errorMessage] as? String
        throw NSError(domain: "untitled", code: 2, userInfo: [
            NSLocalizedDescriptionKey: reason.map { "\(failure) \($0)" } ?? failure])
    }

    static func source(command: String, prompt: String) -> String {
        "do shell script \(command) with prompt \(literal(prompt)) with administrator privileges"
    }

    static func literal(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
