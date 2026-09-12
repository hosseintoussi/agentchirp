import Foundation

// Best-effort cumulative adapter. Lifecycle state never depends on transcript parsing.
func reduceCodex(_ entry: [String: Any], into usage: inout TokenUsage) {
    guard let payload = entry["payload"] as? [String: Any] else { return }
    if entry["type"] as? String == "turn_context", let model = payload["model"] as? String {
        usage.model = model
    }
    guard entry["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
          let info = payload["info"] as? [String: Any],
          let tokens = info["total_token_usage"] as? [String: Any],
          let input = tokens["input_tokens"] as? Int,
          let output = tokens["output_tokens"] as? Int, input >= 0, output >= 0 else { return }
    let cached = min(input, max(0, tokens["cached_input_tokens"] as? Int ?? 0))
    usage.input = input - cached; usage.cache = cached; usage.output = output
}
