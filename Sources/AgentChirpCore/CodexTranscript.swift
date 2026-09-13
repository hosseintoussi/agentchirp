import Foundation

// Best-effort model adapter. Lifecycle state never depends on transcript parsing.
func reduceCodex(_ entry: [String: Any], into summary: inout TranscriptSummary) {
    guard entry["type"] as? String == "turn_context", let payload = entry["payload"] as? [String: Any],
          let model = payload["model"] as? String, !model.isEmpty else { return }
    summary.model = model
}
