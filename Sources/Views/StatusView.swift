import SwiftUI

/// Claude Code status and setup, in the spirit of /status and /usage.
enum StatusWidget: String, BoardWidget {
    case claudeCode, account, mcp, customization
    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .account: "Compte"
        case .mcp: "Serveurs MCP"
        case .customization: "Personnalisation"
        }
    }
    var symbol: String {
        switch self {
        case .claudeCode: "terminal"
        case .account: "person.crop.circle"
        case .mcp: "server.rack"
        case .customization: "slider.horizontal.3"
        }
    }
}

/// Claude Code status and setup, in the spirit of /status and /usage.
struct StatusView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        WidgetBoard(orderKey: "status.order", hiddenKey: "status.hidden") { (w: StatusWidget) in
            switch w {
            case .claudeCode: claudeBlock
            case .account: accountBlock
            case .mcp: mcpBlock
            case .customization: customBlock
            }
        }
    }

    private var claudeBlock: some View {
        let st = store.claude
        return Block(title: "Claude Code", note: st.version.map { "version \($0)" }) {
            VStack(spacing: 0) {
                row("terminal", "Sessions actives", "\(store.live.count)")
                row("cpu", "Modèle", st.model ?? "—")
                row("gauge.with.dots.needle.50percent", "Effort", st.effort.map(ContextBlock.effort) ?? "—")
                row("brain", "Réflexion", st.thinking.map { $0 ? "activée" : "désactivée" } ?? "—")
                row("hare", "Mode rapide", st.fast.map { $0 ? "activé" : "désactivé" } ?? "—")
                row("textformat", "Style de sortie", st.outputStyle ?? "—")
                row("lock.shield", "Permissions", st.permissionMode.map(Self.mode) ?? "par défaut")
                row("globe", "Langue", st.language ?? "—", last: true)
            }
        }
    }

    private var accountBlock: some View {
        Block(title: "Compte") {
            VStack(spacing: 0) {
                row("person.crop.circle", "Offre", store.account.plan ?? "—")
                row("speedometer", "Limites", store.account.limits ?? "—")
                row("plus.circle", "Usage supplémentaire", store.account.extraUsage ? "activé" : "désactivé")
                row("link", "Ligne d'état", store.link == .connected ? "connectée" : "non connectée", last: true)
            }
        }
    }

    private var customBlock: some View {
        let st = store.claude
        return Block(title: "Personnalisation") {
            VStack(spacing: 0) {
                row("bolt.horizontal", "Hooks", st.hooks.isEmpty ? "aucun" : st.hooks.joined(separator: ", "))
                row("sparkles", "Skills", "\(st.skills)")
                row("person.2", "Agents", "\(st.agents)")
                row("slash.circle", "Commandes", "\(st.commands)")
                row("puzzlepiece", "Plugins activés", "\(st.plugins)")
                row("doc.text", "CLAUDE.md", st.claudeMdBytes > 0 ? "≈ \(st.claudeMdBytes / 4) tokens" : "absent")
                row("tray.full", "Mémoires", "\(st.memories) fichiers", last: true)
            }
        }
    }

    private var mcpBlock: some View {
        let inv = store.mcp
        return Block(title: "Serveurs MCP", note: inv.map { "\($0.servers.count) actifs" } ?? "vérification…") {
            if let inv {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(McpServer.Scope.allCases, id: \.rawValue) { scope in
                        McpScopeSection(scope: scope, servers: inv.servers.filter { $0.scope == scope })
                    }
                    if inv.hiddenConnectors > 0 {
                        Text("\(inv.hiddenConnectors) connecteurs claude.ai non utilisés masqués, comme dans /mcp.")
                            .font(Theme.sans(11.5)).foregroundStyle(Theme.inkFaint)
                    }
                    Text("Les serveurs intégrés par les plugins de Claude Code (comme easel) n'apparaissent ici qu'après avoir été utilisés : Claude Code ne les écrit nulle part sur le disque.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
                }
                Button { store.mcp = nil; store.refreshMcp() } label: {
                    Label("Revérifier", systemImage: "arrow.clockwise").font(Theme.sans(12, .medium)).foregroundStyle(Theme.clayDeep)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude Code vérifie l'état de chaque serveur…").font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft)
                }
            }
        }
    }

    static func mode(_ m: String) -> String {
        ["auto": "automatique", "default": "par défaut", "acceptEdits": "accepter les modifications", "plan": "plan",
         "bypassPermissions": "sans confirmation"][m] ?? m
    }

    private func row(_ symbol: String, _ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.clay)
                    .frame(width: 26, height: 26)
                    .background(Theme.clay.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(label).font(Theme.sans(13)).foregroundStyle(Theme.inkSoft)
                Spacer(minLength: 12)
                Text(value).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.trailing).lineLimit(2)
            }
            .padding(.vertical, 7)
            if !last { Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.leading, 37) }
        }
    }
}


/// One scope of /mcp (project, user, claude.ai, built-in) with each server's health.
struct McpScopeSection: View {
    let scope: McpServer.Scope
    let servers: [McpServer]

    var body: some View {
        if !servers.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                ForEach(servers) { m in
                    HStack(spacing: 9) {
                        Image(systemName: symbol(m.health)).foregroundStyle(color(m.health))
                        Text(m.name).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(label(m.health)).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
    }

    private var title: String {
        switch scope {
        case .project: return "Projet" + (servers.first.map { " · \($0.detail)" } ?? "")
        case .user: return "Utilisateur"
        case .claudeAI: return "claude.ai"
        case .builtIn: return "Intégrés à Claude Code"
        }
    }
    private func symbol(_ h: McpServer.Health) -> String {
        h == .connected ? "checkmark.circle.fill" : h == .needsAuth ? "exclamationmark.circle.fill" : "xmark.circle.fill"
    }
    private func color(_ h: McpServer.Health) -> Color { h == .connected ? .green : h == .needsAuth ? .orange : .red }
    private func label(_ h: McpServer.Health) -> String {
        h == .connected ? "connecté" : h == .needsAuth ? "à authentifier" : h == .failed ? "en échec" : "inconnu"
    }
}
