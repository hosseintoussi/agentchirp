import Foundation

// Best-effort adapter for local Codex JSONL. Lifecycle state comes from supported
// hooks, never transcript mtime. Codex documents the transcript format as unstable.
private struct CodexTokens {
    var input = 0, output = 0, cache = 0
    var model = ""
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var mtime = Date.distantPast
    var fileID: UInt64 = 0
}
private var codexTokenCache: [String: CodexTokens] = [:]

func evictCodexTokenCache(keeping paths: Set<String>) {
    codexTokenCache = codexTokenCache.filter { paths.contains($0.key) }
}

public func readCodexTokens(_ path: String) -> (input: Int, output: Int, cache: Int, model: String) {
    guard !path.isEmpty,
          let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return (0, 0, 0, "") }
    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let mtime = attrs[.modificationDate] as? Date ?? .distantPast
    var snapshot = codexTokenCache[path] ?? CodexTokens()
    if snapshot.fileID != fileID || size < snapshot.offset || (size == snapshot.size && mtime != snapshot.mtime) {
        snapshot = CodexTokens()
    }
    if snapshot.size != size || snapshot.mtime != mtime {
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if (try? handle.seek(toOffset: snapshot.offset)) != nil, let tail = try? handle.readToEnd() {
                let end = tail.lastIndex(of: 10).map { tail.index(after: $0) } ?? tail.startIndex
                for line in tail[..<end].split(separator: 10) {
                    guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let payload = entry["payload"] as? [String: Any] else { continue }
                    if entry["type"] as? String == "turn_context", let model = payload["model"] as? String {
                        snapshot.model = model
                    }
                    guard entry["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let usage = info["total_token_usage"] as? [String: Any],
                          let input = usage["input_tokens"] as? Int,
                          let output = usage["output_tokens"] as? Int,
                          input >= 0, output >= 0 else { continue }
                    // These are cumulative totals, not deltas. Cached tokens are a
                    // subset of input; split them out for the console's IN/CACHE columns.
                    let cached = min(input, max(0, usage["cached_input_tokens"] as? Int ?? 0))
                    snapshot.input = input - cached
                    snapshot.cache = cached
                    snapshot.output = output
                }
                snapshot.offset += UInt64(end - tail.startIndex)
            }
        }
        snapshot.size = size; snapshot.mtime = mtime; snapshot.fileID = fileID
        codexTokenCache[path] = snapshot
    }
    return (snapshot.input, snapshot.output, snapshot.cache, snapshot.model)
}
