import Foundation

/// Plan information from ~/.claude.json (only non-sensitive fields are read).
struct AccountInfo {
    var plan: String?
    var limits: String?
    var extraUsage = false

    static func load() -> AccountInfo {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return AccountInfo() }
        var info = AccountInfo()
        switch account["organizationType"] as? String {
        case "claude_team": info.plan = "Claude Team"
        case "claude_enterprise": info.plan = "Claude Enterprise"
        case "claude_max": info.plan = "Claude Max"
        case "claude_pro": info.plan = "Claude Pro"
        case let other?: info.plan = other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: break
        }
        if let tier = account["userRateLimitTier"] as? String {
            if tier.contains("max_20x") { info.limits = "Max 20x" }
            else if tier.contains("max_5x") { info.limits = "Max 5x" }
            else if tier.contains("pro") { info.limits = "Pro" }
        }
        info.extraUsage = account["hasExtraUsageEnabled"] as? Bool ?? false
        return info
    }
}
