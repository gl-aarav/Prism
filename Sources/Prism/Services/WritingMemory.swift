import Foundation

/// Stores writing style samples from accepted suggestions to help
/// the AI learn how the user writes. Entries auto-expire after 7 days.
class WritingMemory {
    static let shared = WritingMemory()

    /// A single memory entry: what the user typed + what they accepted.
    struct Entry: Codable {
        let context: String      // Text before cursor when suggestion was accepted
        let accepted: String     // The text the user accepted
        let timestamp: Date      // When it was accepted
        let appBundleId: String? // Which app it happened in
    }

    private let fileURL: URL
    private let maxAge: TimeInterval = 7 * 24 * 3600  // 7 days
    private let maxEntries = 200  // Cap stored entries
    private var entries: [Entry] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Prism/Cotypist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("writing_memory.json")
        load()
    }

    // MARK: - Public API

    /// Record that the user accepted a suggestion.
    func record(context: String, accepted: String, appBundleId: String? = nil) {
        // Only store meaningful entries (at least 5 chars of context and 3 chars accepted)
        guard context.count >= 5, accepted.count >= 3 else { return }

        // Trim context to last 200 chars to save space
        let trimmedContext = String(context.suffix(200))

        let entry = Entry(
            context: trimmedContext,
            accepted: accepted,
            timestamp: Date(),
            appBundleId: appBundleId
        )

        entries.append(entry)

        // Enforce limits
        pruneExpired()
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }

        save()
    }

    /// Get a writing style summary for the AI prompt.
    /// Returns a compact string of recent accepted completions.
    func getStyleContext(limit: Int = 15) -> String {
        pruneExpired()

        guard !entries.isEmpty else { return "" }

        // Take the most recent entries
        let recent = entries.suffix(limit)
        var lines: [String] = []
        for entry in recent {
            // Show just the accepted text, not the full context
            lines.append("- \"\(entry.accepted.prefix(100))\"")
        }

        return """
            The user has previously accepted these completions (use this to match their writing style):
            \(lines.joined(separator: "\n"))
            """
    }

    /// Total number of stored entries.
    var count: Int {
        pruneExpired()
        return entries.count
    }

    /// Clear all stored memory.
    func clearAll() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        pruneExpired()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries.removeAll { $0.timestamp < cutoff }
    }
}
