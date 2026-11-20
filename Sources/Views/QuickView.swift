import SwiftUI

/// "⚡ Rapide": one field (typed or dictated) and one "Vers" picker:
/// a new project in a new iTerm tab, a message to an open session (or all), or a one-off ephemeral agent.
@MainActor
struct QuickView: View {
    @Environment(UsageStore.self) private var store
    @Binding var dictate: Bool
    let close: () -> Void
    /// Shown in its own floating window: the window's title bar replaces this header.
    var floating = false
    @State private var center = SendCenter.shared
    @State private var dictation = Dictation()
    @State private var launchError: String?
    @State private var launching = false
    @State private var pickerOpen = false
    @FocusState private var fieldFocused: Bool
    @AppStorage("quickDraft") private var text = ""
    /// "eph", "all", "sess:<id>" or "proj:<path>".
    @AppStorage("quickTarget") private var target = "eph"

    private var sessions: [LiveSession] {
        store.live.values.filter { !$0.name.isEmpty && $0.kind != "background" && !$0.name.hasPrefix("my-claude-code") }
            .sorted { $0.name < $1.name }
    }

    /// Recent project folders, most recent first.
    private var projects: [(path: String, last: Double)] {
        var seen = Set<String>(), out: [(String, Double)] = []
        for s in store.snapshot.sessions.sorted(by: { $0.info.last > $1.info.last }) {
            let p = s.info.project
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard !p.isEmpty, p != home, !(p as NSString).lastPathComponent.hasPrefix("."), !p.contains("/."),
                  !seen.contains(p), FileManager.default.fileExists(atPath: p) else { continue }
            seen.insert(p); out.append((p, s.info.last))
            if out.count == 5 { break }
        }
        return out
    }

    private enum Dest { case ephemeral, all, session(LiveSession), project(String) }

    private var dest: Dest {
        if target == "all", sessions.count > 1 { return .all }
        if target.hasPrefix("sess:"), let s = sessions.first(where: { $0.sessionId == String(target.dropFirst(5)) }) { return .session(s) }
        if target.hasPrefix("proj:") { return .project(String(target.dropFirst(5))) }
        return .ephemeral
    }

    private var destLabel: (symbol: String, title: String, hint: String, action: String, actionSymbol: String) {
        switch dest {
        case .ephemeral:
            ("sparkles", "Agent éphémère", "Exécute la tâche en arrière-plan avec vos réglages, vous rend compte ici, puis se ferme.", "Lancer", "play.fill")
        case .all:
            ("person.3.fill", "Toutes les sessions", "Le message est transmis à chaque session ouverte par la messagerie entre sessions.", "Envoyer", "arrow.up")
        case .session(let s):
            ("at", s.name, "Le message est transmis à cette session ; sa réponse arrive dans son chat.", "Envoyer", "arrow.up")
        case .project(let p):
            ("folder.fill", (p as NSString).lastPathComponent,
             "Nouvelle session Claude Code dans un onglet de votre fenêtre iTerm, avec cette consigne comme premier message.",
             "Ouvrir dans iTerm", "plus.rectangle.on.rectangle")
        }
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 14) {
                if !floating {
                HStack {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.clay)
                    Text("Commande rapide").font(Theme.sans(16, .bold)).foregroundStyle(Theme.ink)
                    Spacer()
                    DetachButton(detached: MiniWindows.shared.isOpen(.quick)) {
                        if MiniWindows.shared.isOpen(.quick) { MiniWindows.shared.close(.quick) }
                        else { MiniWindows.shared.open(.quick); close() }
                    }
                    .tip(MiniWindows.shared.isOpen(.quick) ? "Détachée · cliquer pour fermer la fenêtre flottante" : "Détacher en fenêtre flottante")
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkSoft)
                            .frame(width: 26, height: 26).background(Circle().fill(Theme.rule.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                }
                }

                HStack(alignment: .bottom, spacing: 8) {
                    Button { dictation.toggle() } label: {
                        Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(dictation.isRecording ? Color.red : Theme.clay)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill((dictation.isRecording ? Color.red : Theme.clay).opacity(0.13)))
                    }
                    .buttonStyle(.plain)
                    TextField("", text: $text, prompt: Text(dictation.isRecording ? "Je vous écoute…" : "Votre consigne…")
                        .foregroundStyle(Theme.inkFaint), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
                        .lineLimit(2...8)
                        .focused($fieldFocused)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(dictation.isRecording ? Color.red.opacity(0.6) : Theme.rule, lineWidth: dictation.isRecording ? 1.5 : 0.5))
                        .onSubmit(send)
                }
                if let error = dictation.error { Text(error).font(Theme.sans(11.5)).foregroundStyle(.orange) }

                // Destination: one picker instead of a list of chips.
                let label = destLabel
                HStack(spacing: 8) {
                    Text("Vers").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.inkSoft)
                    Button { withAnimation(.snappy(duration: 0.22)) { pickerOpen.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: label.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.clay)
                            Text(label.title).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 230, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.inkFaint)
                                .rotationEffect(.degrees(pickerOpen ? 180 : 0))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(pickerOpen ? Theme.clay.opacity(0.10) : Theme.raised))
                        .overlay(Capsule().strokeBorder(pickerOpen ? Theme.clay.opacity(0.5) : Theme.rule, lineWidth: pickerOpen ? 1 : 0.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                if pickerOpen {
                    DestinationPicker(target: $target, projects: projects, sessions: sessions,
                                      pickFolder: pickFolder, close: { withAnimation(.snappy(duration: 0.22)) { pickerOpen = false } })
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(action: send) {
                        HStack(spacing: 6) {
                            if launching { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: label.actionSymbol).font(.system(size: 11, weight: .bold)) }
                            Text(label.action).font(Theme.sans(12.5, .semibold))
                            Text("↩").font(Theme.sans(11)).opacity(0.7)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Capsule().fill(empty ? Theme.inkFaint : Theme.clay))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty || launching)
                    .fixedSize()
                }
                Text(label.hint).font(Theme.sans(11.5)).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
                if let launchError { Text(launchError).font(Theme.sans(11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }

                HStack {
                    Text("Historique des commandes").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    if !center.quickJobs.isEmpty {
                        Text("\(center.quickJobs.count)").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
                    }
                }
                .padding(.top, 8)
                if center.quickJobs.isEmpty {
                    Text("Vos commandes rapides et leurs comptes rendus s'afficheront ici, et resteront conservés.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.inkFaint)
                } else {
                    Text("Balayez une commande vers la gauche pour la supprimer.").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            // History rows: swipe left (trackpad) to delete, or right-click.
            ForEach(Array(center.quickJobs.prefix(50))) { job in
                QuickJobRow(job: job)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { withAnimation { center.delete(job.id) } } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button(role: .destructive) { withAnimation { center.delete(job.id) } } label: { Label("Supprimer", systemImage: "trash") }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .onChange(of: dictation.transcript) { _, t in if dictation.isRecording { text = t } }
        .onAppear {
            // Quick by default: a new project in iTerm only when chosen explicitly, each time.
            if target.hasPrefix("proj:") { target = "eph" }
            fieldFocused = true
            startDictationIfAsked()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPicker)) { _ in pickerOpen = true }
        .onChange(of: dictate) { _, _ in startDictationIfAsked() }
    }

    private func send() {
        dictation.stop()
        let p = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !launching else { return }
        launchError = nil
        switch dest {
        case .project(let dir):
            launching = true
            let job = center.logProject(p, in: dir)
            SessionLauncher.startProject(in: dir, prompt: p) { error in
                launching = false
                center.finishProject(job, in: dir, error: error)
                if let error { launchError = error } else { text = ""; close() }
            }
        case .session(let s): center.quick(p, to: [s]); text = ""
        case .all: center.quick(p, to: sessions); text = ""
        case .ephemeral: center.quick(p, to: []); text = ""
        }
    }

    /// Any folder, through the standard picker (the panel steps aside while it is open).
    private func pickFolder() {
        PanelController.shared.lowerForSystemDialog()
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Choisir"
        open.message = "Dossier du nouveau chantier"
        open.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
        if open.runModal() == .OK, let url = open.url { target = "proj:" + url.path }
        PanelController.shared.restoreAfterSystemDialog()
    }

    private func startDictationIfAsked() {
        guard dictate else { return }
        dictate = false
        fieldFocused = true
        if !dictation.isRecording { dictation.start() }
    }
}

/// A quick command with its status and, once done, the agent's report.
struct QuickJobRow: View {
    let job: SendJob
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if job.isRunning { ProgressView().controlSize(.small) }
                    else { Image(systemName: job.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(job.succeeded ? Color.green : Color.red) }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.prompt).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(expanded ? nil : 2)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(job.recipient) · \(Fmt.time(job.started)) · \(job.isRunning ? "en cours " : "")\(Int(job.duration)) s")
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                    }
                }
                Spacer(minLength: 0)
            }
            if let result = job.result, !result.isEmpty {
                Text(LocalizedStringKey(result)).font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.paper))
                    .padding(.leading, 24)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }
}

/// Destination picker drawn in the app's style (native menus don't open in the non-activating panel).
struct DestinationPicker: View {
    @Binding var target: String
    let projects: [(path: String, last: Double)]
    let sessions: [LiveSession]
    let pickFolder: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                section("Tâche ponctuelle", note: "arrière-plan")
                row(key: "eph", symbol: "sparkles", tint: Theme.clay, title: "Agent éphémère",
                    subtitle: "rend compte ici, puis se ferme", trailing: nil)
                section("Message à une session", note: "ouverte").padding(.top, 8)
                if sessions.isEmpty {
                    Text("Aucune session ouverte").font(Theme.sans(12)).foregroundStyle(Theme.inkFaint).padding(.horizontal, 10).padding(.vertical, 6)
                }
                ForEach(sessions, id: \.sessionId) { s in
                    row(key: "sess:" + s.sessionId, symbol: "at", tint: PhaseBadge.color(s.phase),
                        title: s.name, subtitle: nil, trailing: s.label, mono: true)
                }
                if sessions.count > 1 {
                    row(key: "all", symbol: "person.3.fill", tint: Theme.inkSoft, title: "Toutes les sessions",
                        subtitle: nil, trailing: "\(sessions.count)")
                }

                section("Nouveau chantier", note: "onglet iTerm").padding(.top, 8)
                ForEach(projects, id: \.path) { p in
                    row(key: "proj:" + p.path, symbol: "folder.fill", tint: Theme.clay,
                        title: (p.path as NSString).lastPathComponent, subtitle: shortPath(p.path),
                        trailing: OverviewView.ago(Date(timeIntervalSince1970: p.last)))
                }
                row(key: nil, symbol: "folder.badge.plus", tint: Theme.inkSoft, title: "Autre dossier…", subtitle: nil, trailing: nil) {
                    close(); pickFolder()
                }

            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
    }

    private func section(_ title: String, note: String) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(Theme.sans(10, .bold)).tracking(0.6).foregroundStyle(Theme.inkFaint)
            Text(note).font(Theme.sans(10)).foregroundStyle(Theme.inkFaint.opacity(0.8))
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return (p as NSString).deletingLastPathComponent
    }

    private func row(key: String?, symbol: String, tint: Color, title: String, subtitle: String?, trailing: String?,
                     mono: Bool = false, action: (() -> Void)? = nil) -> some View {
        PickerRow(selected: key != nil && key == target, symbol: symbol, tint: tint, title: title,
                  subtitle: subtitle, trailing: trailing, mono: mono) {
            if let action { action() } else if let key { target = key; close() }
        }
    }
}

private struct PickerRow: View {
    let selected: Bool
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    let trailing: String?
    let mono: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint.opacity(0.13)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(mono ? .system(size: 12, weight: .medium, design: .monospaced) : Theme.sans(12.5, .semibold))
                        .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing).font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint).lineLimit(1)
                }
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.clay)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.clay.opacity(0.10) : hovering ? Theme.rule.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
