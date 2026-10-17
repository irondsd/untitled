import Foundation
import CryptoKit

struct NoteRecord: Codable, Identifiable {
    var id: UUID
    var title: String?
    var filePath: String?
    var savedFileHash: String?
    var createdAt: Date
    var modifiedAt: Date
    var archivedAt: Date?
    var selectionLocation: Int = 0
    var selectionLength: Int = 0
    var scrollOffset: Double = 0
    /// Raw NoteLanguage value chosen from the Syntax menu; nil follows automatic detection.
    /// Kept as a string so an unknown future value never makes the metadata unreadable.
    var syntax: String?
    /// True when the note began as a local copy of a file opened from disk, not as a scratch note.
    var openedFromFile: Bool?

    var syntaxOverride: NoteLanguage? { syntax.flatMap(NoteLanguage.init(rawValue:)) }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let filePath { return URL(fileURLWithPath: filePath).lastPathComponent }
        return "untitled"
    }
}

struct NoteSession: Codable {
    var openIDs: [UUID] = []
    var selectedID: UUID?
}

/// Text files are authoritative. A missing metadata file or session index never deletes a note.
final class NotesStore {
    let root: URL
    let notesDirectory: URL
    private(set) var records: [UUID: NoteRecord] = [:]
    private(set) var session = NoteSession()
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .millisecondsSince1970
        return value
    }()
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .millisecondsSince1970
        return value
    }()

    init(root: URL) throws {
        self.root = root
        notesDirectory = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: notesDirectory, includingPropertiesForKeys: nil)
        // A deletion marker prevents an interrupted delete from resurrecting text as an orphan.
        let deleted = Set(files.filter { $0.pathExtension == "deleted" }.compactMap {
            UUID(uuidString: $0.deletingPathExtension().lastPathComponent)
        })
        for id in deleted { try removeLocalFiles(id) }
        for file in files where file.pathExtension == "txt" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !deleted.contains(id) else { continue }
            let metadata = metadataURL(id)
            if let data = try? Data(contentsOf: metadata),
               var record = try? decoder.decode(NoteRecord.self, from: data) {
                record.id = id
                records[id] = record
            } else {
                // Recover orphan text into the archive without changing its contents.
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let modified = attributes?[.modificationDate] as? Date ?? Date()
                records[id] = NoteRecord(id: id, title: nil, filePath: nil,
                    createdAt: modified, modifiedAt: modified, archivedAt: modified)
            }
        }
        if let data = try? Data(contentsOf: sessionURL),
           let saved = try? decoder.decode(NoteSession.self, from: data) {
            var seen = Set<UUID>()
            session.openIDs = saved.openIDs.filter { records[$0] != nil && seen.insert($0).inserted }
            session.selectedID = session.openIDs.contains(saved.selectedID ?? UUID()) ? saved.selectedID : session.openIDs.first
            // An atomic session write may have been interrupted after writing note metadata.
            for id in session.openIDs { records[id]?.archivedAt = nil }
        } else {
            session.openIDs = records.values.filter { $0.archivedAt == nil }
                .sorted { $0.createdAt < $1.createdAt }.map(\.id)
            session.selectedID = session.openIDs.first
        }
        // Notes not present in the session remain recoverable in the archive.
        for id in Array(records.keys) where !session.openIDs.contains(id) {
            if var record = records[id], record.archivedAt == nil {
                record.archivedAt = record.modifiedAt
                records[id] = record
            }
        }
        if session.openIDs.isEmpty { _ = try create() }
    }

    private var sessionURL: URL { root.appendingPathComponent("session.json") }
    func textURL(_ id: UUID) -> URL { notesDirectory.appendingPathComponent("\(id.uuidString).txt") }
    private func metadataURL(_ id: UUID) -> URL { notesDirectory.appendingPathComponent("\(id.uuidString).json") }
    func text(_ id: UUID) throws -> String { try String(contentsOf: textURL(id), encoding: .utf8) }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func writeRecord(_ record: NoteRecord) throws {
        try encoder.encode(record).write(to: metadataURL(record.id), options: .atomic)
    }
    func saveSession() throws { try encoder.encode(session).write(to: sessionURL, options: .atomic) }

    @discardableResult
    func create(text: String = "", filePath: String? = nil) throws -> UUID {
        let id = UUID(), now = Date()
        let record = NoteRecord(id: id, title: nil, filePath: filePath,
            savedFileHash: filePath == nil ? nil : Self.hash(text),
            createdAt: now, modifiedAt: now, archivedAt: nil, openedFromFile: filePath == nil ? nil : true)
        try text.write(to: textURL(id), atomically: true, encoding: .utf8)
        try writeRecord(record)
        records[id] = record
        session.openIDs.append(id)
        session.selectedID = id
        try saveSession()
        return id
    }

    func saveText(_ text: String, for id: UUID) throws {
        guard var record = records[id] else { return }
        try text.write(to: textURL(id), atomically: true, encoding: .utf8)
        record.modifiedAt = Date()
        try writeRecord(record)
        records[id] = record
    }

    func savePosition(_ id: UUID, location: Int, length: Int, offset: Double) throws {
        guard var record = records[id] else { return }
        record.selectionLocation = location
        record.selectionLength = length
        record.scrollOffset = offset
        try writeRecord(record)
        records[id] = record
    }

    func rename(_ id: UUID, title: String) throws {
        guard var record = records[id] else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.title = clean.isEmpty ? nil : clean
        try writeRecord(record)
        records[id] = record
    }

    func setSyntax(_ id: UUID, language: NoteLanguage?) throws {
        guard var record = records[id] else { return }
        record.syntax = language?.rawValue
        try writeRecord(record)
        records[id] = record
    }

    func associateFile(_ id: UUID, url: URL, text: String) throws {
        guard var record = records[id] else { return }
        record.filePath = url.path
        record.savedFileHash = Self.hash(text)
        try writeRecord(record)
        records[id] = record
    }

    func select(_ id: UUID) throws {
        guard session.openIDs.contains(id) else { return }
        session.selectedID = id
        try saveSession()
    }

    func archive(_ id: UUID) throws {
        guard var record = records[id], let index = session.openIDs.firstIndex(of: id) else { return }
        let body = try text(id)
        // A file opened from disk already lives there; keep its local copy only when it holds unsaved edits.
        let retain = record.openedFromFile == true
            ? Self.hash(body) != record.savedFileHash
            : !Self.isBlankScratch(record, body: body)
        record.archivedAt = Date()
        if retain { try writeRecord(record) }
        var next = session
        next.openIDs.remove(at: index)
        if next.selectedID == id {
            next.selectedID = next.openIDs.isEmpty ? nil : next.openIDs[min(index, next.openIDs.count - 1)]
        }
        // The session write commits the transition; rollback memory if that write fails.
        try encoder.encode(next).write(to: sessionURL, options: .atomic)
        session = next
        if retain { records[id] = record }
        else {
            try removeLocalFiles(id)
            records.removeValue(forKey: id)
        }
        if session.openIDs.isEmpty { _ = try create() }
    }

    /// An unnamed, whitespace-only note that never belonged to a file; closing it keeps nothing.
    func isBlankScratch(_ id: UUID) throws -> Bool {
        guard let record = records[id], record.openedFromFile != true else { return false }
        return Self.isBlankScratch(record, body: try text(id))
    }
    private static func isBlankScratch(_ record: NoteRecord, body: String) -> Bool {
        record.title == nil && record.filePath == nil && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func deleteArchived(_ id: UUID) throws {
        guard records[id] != nil else { return }
        guard !session.openIDs.contains(id) else {
            throw NSError(domain: "untitled", code: 2, userInfo: [NSLocalizedDescriptionKey: "Close this note before deleting it."])
        }
        try removeLocalFiles(id)
        records.removeValue(forKey: id)
    }

    private func removeLocalFiles(_ id: UUID) throws {
        let marker = notesDirectory.appendingPathComponent("\(id.uuidString).deleted")
        try Data().write(to: marker, options: .atomic)
        for url in [textURL(id), metadataURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.removeItem(at: marker)
    }

    func restore(_ id: UUID) throws {
        guard var record = records[id] else { return }
        var next = session
        if !next.openIDs.contains(id) { next.openIDs.append(id) }
        record.archivedAt = nil
        try writeRecord(record)
        next.selectedID = id
        try encoder.encode(next).write(to: sessionURL, options: .atomic)
        records[id] = record
        session = next
    }

    /// Moves an open tab, clamping the position to the tab strip.
    func move(_ id: UUID, to index: Int) throws {
        guard let current = session.openIDs.firstIndex(of: id) else { return }
        var next = session
        next.openIDs.remove(at: current)
        next.openIDs.insert(id, at: max(0, min(index, next.openIDs.count)))
        guard next.openIDs != session.openIDs else { return }
        try encoder.encode(next).write(to: sessionURL, options: .atomic)
        session = next
    }

    var archived: [NoteRecord] {
        records.values.filter { !session.openIDs.contains($0.id) }
            .sorted { ($0.archivedAt ?? $0.modifiedAt) > ($1.archivedAt ?? $1.modifiedAt) }
    }
}
