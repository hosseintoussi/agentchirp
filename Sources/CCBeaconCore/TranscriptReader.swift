import Foundation

public struct TokenUsage {
    public var input = 0, output = 0, cache = 0
    public var model = ""
}

/// Shared incremental transport with provider-specific record reducers.
/// Each owner confines this reader to its own queue.
public final class TranscriptReader {
    private struct Snapshot {
        var usage = TokenUsage()
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
    public func read(_ path: String, provider: AgentProvider) -> TokenUsage {
        guard !path.isEmpty, let attrs = try? fileManager.attributesOfItem(atPath: path) else {
            caches[provider]?[path] = nil
            return TokenUsage()
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        var snapshot = caches[provider]?[path] ?? Snapshot()
        if snapshot.fileID != fileID || size < snapshot.size || (size == snapshot.size && mtime != snapshot.mtime) {
            snapshot = Snapshot()
        }
        if snapshot.fileID == fileID && snapshot.size == size && snapshot.mtime == mtime { return snapshot.usage }
        // A failed read must not advance metadata: unchanged files are retried next tick.
        guard let tail = try? readTail(path, snapshot.offset) else { return snapshot.usage }
        let end = tail.lastIndex(of: 10).map { tail.index(after: $0) } ?? tail.startIndex
        for line in tail[..<end].split(separator: 10) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch provider {
            case .claude: reduceClaude(entry, into: &snapshot.usage)
            case .codex: reduceCodex(entry, into: &snapshot.usage)
            }
        }
        snapshot.offset += UInt64(end - tail.startIndex)
        snapshot.size = size; snapshot.mtime = mtime; snapshot.fileID = fileID
        caches[provider, default: [:]][path] = snapshot
        return snapshot.usage
    }
}

private func reduceClaude(_ entry: [String: Any], into usage: inout TokenUsage) {
    guard entry["type"] as? String == "assistant",
          let message = entry["message"] as? [String: Any],
          let tokens = message["usage"] as? [String: Any] else { return }
    usage.input += max(0, tokens["input_tokens"] as? Int ?? 0)
    usage.output += max(0, tokens["output_tokens"] as? Int ?? 0)
    usage.cache += max(0, tokens["cache_creation_input_tokens"] as? Int ?? 0)
        + max(0, tokens["cache_read_input_tokens"] as? Int ?? 0)
    if let model = message["model"] as? String, !model.isEmpty { usage.model = model }
}

// Standalone convenience readers for the CLI fixtures.
private let standaloneReader = TranscriptReader()
public func readTokens(_ path: String) -> TokenUsage { standaloneReader.read(path, provider: .claude) }
public func readCodexTokens(_ path: String) -> TokenUsage { standaloneReader.read(path, provider: .codex) }
