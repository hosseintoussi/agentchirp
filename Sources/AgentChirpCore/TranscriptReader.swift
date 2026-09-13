import Foundation

/// What the console needs from a transcript: the model in use and whether the
/// user interrupted the turn, which no Claude Code hook reports.
public struct TranscriptSummary: Equatable {
    public var model = ""
    /// Time of the latest `[Request interrupted by user…]` entry with no assistant
    /// output after it, or nil when the transcript ends in regular traffic.
    public var interruptedAt: TimeInterval?
    public init(model: String = "", interruptedAt: TimeInterval? = nil) {
        self.model = model; self.interruptedAt = interruptedAt
    }
}

/// Shared incremental transport with provider-specific record reducers.
/// Each owner confines this reader to its own queue.
public final class TranscriptReader {
    private struct Snapshot {
        var summary = TranscriptSummary()
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var mtime = Date.distantPast
        var fileID: UInt64 = 0
    }
    private var caches: [AgentProvider: [String: Snapshot]] = [:]
    private let fileManager: FileManager
    private let readTail: (String, UInt64) throws -> Data
    public init(fileManager: FileManager = .default,
                readTail: @escaping (String, UInt64) throws -> Data = { path, offset in
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    defer { try? handle.close() }
                    try handle.seek(toOffset: offset)
                    return try handle.readToEnd() ?? Data()
                }) {
        self.fileManager = fileManager; self.readTail = readTail
    }
    public func evict(provider: AgentProvider, keeping paths: Set<String>) {
        caches[provider] = (caches[provider] ?? [:]).filter { paths.contains($0.key) }
    }
    public func read(_ path: String, provider: AgentProvider) -> TranscriptSummary {
        guard !path.isEmpty, let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            caches[provider]?[path] = nil
            return TranscriptSummary()
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        var snapshot = caches[provider]?[path] ?? Snapshot()
        if snapshot.fileID != fileID || size < snapshot.size || (size == snapshot.size && mtime != snapshot.mtime) {
            snapshot = Snapshot()
        }
        if snapshot.fileID == fileID && snapshot.size == size && snapshot.mtime == mtime { return snapshot.summary }
        // A failed read must not advance metadata: unchanged files are retried next tick.
        guard let tail = try? readTail(path, snapshot.offset) else { return snapshot.summary }
        let end = tail.lastIndex(of: 10).map { tail.index(after: $0) } ?? tail.startIndex
        for line in tail[..<end].split(separator: 10) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch provider {
            case .claude: reduceClaude(entry, into: &snapshot.summary, writtenAt: mtime.timeIntervalSince1970)
            case .codex: reduceCodex(entry, into: &snapshot.summary)
            }
        }
        snapshot.offset += UInt64(end - tail.startIndex)
        snapshot.size = size; snapshot.mtime = mtime; snapshot.fileID = fileID
        caches[provider, default: [:]][path] = snapshot
        return snapshot.summary
    }
}

private let fractionalTimestamps: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let wholeSecondTimestamps = ISO8601DateFormatter()

private func entryTime(_ entry: [String: Any], fallback: TimeInterval) -> TimeInterval {
    guard let text = entry["timestamp"] as? String else { return fallback }
    return (fractionalTimestamps.date(from: text) ?? wholeSecondTimestamps.date(from: text))?.timeIntervalSince1970 ?? fallback
}

/// Claude Code writes one line per assistant content block; the model is the same
/// on each. Stop hooks do not fire on Escape, so the interrupt marker Claude Code
/// records in the transcript is the only signal that a working turn ended.
private func reduceClaude(_ entry: [String: Any], into summary: inout TranscriptSummary, writtenAt: TimeInterval) {
    guard let message = entry["message"] as? [String: Any] else { return }
    switch entry["type"] as? String {
    case "assistant":
        summary.interruptedAt = nil
        if let model = message["model"] as? String, !model.isEmpty { summary.model = model }
    case "user":
        guard let blocks = message["content"] as? [[String: Any]], blocks.contains(where: {
            $0["type"] as? String == "text" && ($0["text"] as? String ?? "").hasPrefix("[Request interrupted by user")
        }) else { return }
        summary.interruptedAt = entryTime(entry, fallback: writtenAt)
    default:
        return
    }
}

// Standalone convenience reader for the CLI fixtures.
private let standaloneReader = TranscriptReader()
public func readTranscript(_ path: String, provider: AgentProvider = .claude) -> TranscriptSummary {
    standaloneReader.read(path, provider: provider)
}
