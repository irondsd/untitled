import Foundation

struct CLIWaitRequest {
    let file: URL

    init?(file: URL) {
        let directory = file.deletingLastPathComponent()
        guard file.isFileURL, file.lastPathComponent == "request.unt-wait",
              directory.lastPathComponent.hasPrefix("unt-wait."),
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return nil }
        self.file = file
    }

    private func replyURL(_ name: String) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(name)
    }

    var isPending: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    var hasReply: Bool {
        ["accepted", "result"].contains { FileManager.default.fileExists(atPath: replyURL($0).path) }
    }

    func files() throws -> [URL] {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let data = try Data(contentsOf: file)
        let paths = data.split(separator: 0)
        guard !paths.isEmpty, let last = data.last, last == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try paths.map {
            guard let path = String(bytes: $0, encoding: .utf8), path.hasPrefix("/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    func accept() throws {
        try String(ProcessInfo.processInfo.processIdentifier).write(to: replyURL("accepted"), atomically: true, encoding: .utf8)
    }

    func finish(_ error: String = "") {
        guard isPending else { return }
        // The CLI owns the directory and may remove it while cancelling the request.
        try? error.write(to: replyURL("result"), atomically: true, encoding: .utf8)
    }
}
