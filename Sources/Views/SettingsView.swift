import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage("menuBarStyle") private var style = "both"
    @AppStorage("alertThreshold") private var threshold = 70.0
    @AppStorage("alertOpensPanel") private var opensPanel = true
    @AppStorage("usagePollInterval") private var pollInterval = 60.0
    @AppStorage("notify.finished") private var nFinished = true
    @AppStorage("notify.waiting") private var nWaiting = true
    @AppStorage("notify.context") private var nContext = true
    @AppStorage("notify.quota") private var nQuota = true
    @AppStorage("notify.digest") private var nDigest = true
    @AppStorage("digest.hour") private var digestHour = 18
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @State private var cleanupDays = 90
    @State private var candidates = SessionFiles.Candidates()
    @State private var totalSize: UInt64 = 0
    @State private var confirmCleanup = false
    @State private var cleanupDone: String?

    var body: some View {
        Form {
            Section("Général") {
                Toggle("Lancer My Claude Code à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Picker("Barre des menus", selection: $style) {
                    Text("Session + semaine (%)").tag("both")
                    Text("Coût du jour ($)").tag("today")
                }
                .pickerStyle(.radioGroup)
                .onChange(of: style) { _, _ in PanelController.shared.refreshButton() }
            }
            Section {
                Toggle("Une session a terminé son travail", isOn: $nFinished)
                Toggle("Une session attend votre réponse", isOn: $nWaiting)
                Toggle("Contexte proche de la compaction (85 %)", isOn: $nContext)
                Toggle("Limites du forfait (seuil et rythme d’épuisement)", isOn: $nQuota)
                Toggle("Bilan de la journée", isOn: $nDigest)
                if nDigest {
                    LabeledContent("Heure du bilan") {
                        Picker("", selection: $digestHour) {
                            ForEach([17, 18, 19, 20], id: \.self) { Text("\($0) h 30").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            } header: {
                Text("Alertes")
            } footer: {
                Text("Affichées uniquement dans le centre de notifications de l'app (la cloche en haut du panneau, détachable), jamais dans celui de macOS. Un point sur l'icône de la barre des menus signale qu'une notification attend.")
                    .font(.system(size: 10.5))
            }
            Section {
                switch store.link {
                case .connected:
                    LabeledContent("Claude Code", value: "connecté")
                    Button("Déconnecter (retire la ligne d'état)") { try? ClaudeCodeLink.disconnect(); store.refreshPlan() }
                case .notConnected:
                    LabeledContent("Claude Code", value: "non connecté")
                    Button("Connecter à Claude Code") { try? ClaudeCodeLink.connect(); store.refreshPlan() }
                case .otherStatusLine(let command):
                    LabeledContent("Ligne d'état actuelle", value: command)
                    Button("Remplacer par celle de My Claude Code") { try? ClaudeCodeLink.connect(); store.refreshPlan() }
                }
                VStack(alignment: .leading) {
                    HStack { Text("Alerte à partir de"); Spacer(); Text("\(Int(threshold)) %").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { threshold }, set: { threshold = ($0 / 5).rounded() * 5 }), in: 50...95).controlSize(.small)
                }
                Toggle("Ouvrir le panneau automatiquement en cas d'alerte", isOn: $opensPanel)
                LabeledContent("Actualiser /usage toutes les") {
                    Picker("", selection: $pollInterval) {
                        Text("1 min").tag(60.0)
                        Text("2 min").tag(120.0)
                        Text("5 min").tag(300.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .onChange(of: pollInterval) { _, _ in store.schedulePolling() }
            } header: {
                Text("Limites et alertes")
            } footer: {
                Text("Les chiffres viennent de /usage, interrogé en arrière-plan (sans coût ni session enregistrée), et de la ligne d'état de Claude Code pendant que vous travaillez. Une sauvegarde de settings.json est conservée.")
                    .font(.system(size: 10.5))
            }
            Section {
                LabeledContent("Journaux de Claude Code", value: Fmt.bytes(totalSize))
                LabeledContent("Sessions inactives depuis") {
                    Picker("", selection: $cleanupDays) {
                        Text("30 j").tag(30)
                        Text("90 j").tag(90)
                        Text("180 j").tag(180)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                LabeledContent("Concernées", value: "\(candidates.sessions.count) sessions · \(Fmt.bytes(candidates.bytes))")
                if confirmCleanup {
                    HStack {
                        Button("Annuler") { confirmCleanup = false }
                        Spacer()
                        Button("Confirmer : \(candidates.sessions.count) sessions à la Corbeille") {
                            let n = SessionFiles.trash(candidates.files)
                            confirmCleanup = false
                            cleanupDone = "\(n) fichiers placés à la Corbeille."
                            refreshCleanup()
                        }
                        .foregroundStyle(Theme.clayDeep)
                    }
                } else {
                    Button("Placer ces sessions à la Corbeille…") { confirmCleanup = true }
                        .disabled(candidates.sessions.isEmpty)
                }
                if let cleanupDone { Text(cleanupDone).font(.caption).foregroundStyle(Theme.sage) }
            } header: {
                Text("Nettoyage")
            } footer: {
                Text("Les fichiers vont à la Corbeille et restent récupérables. Vos statistiques sont conservées ; ces sessions ne pourront simplement plus être reprises avec claude --resume.")
                    .font(.system(size: 10.5))
            }
            Section("Votre offre") {
                LabeledContent("Offre", value: store.account.plan ?? "inconnue")
                LabeledContent("Limites", value: store.account.limits ?? "inconnues")
                LabeledContent("Usage supplémentaire", value: store.account.extraUsage ? "activé" : "désactivé")
            }
            Section {
                Button("Recalculer toutes les statistiques") { store.rebuild() }
            } header: {
                Text("Données")
            } footer: {
                Text("Coûts calculés en équivalent tarif public de l'API Claude (\(Pricing.asOf)). Seuls les compteurs d'usage des journaux de Claude Code sont lus, jamais le texte des conversations, et rien ne quitte votre Mac.")
                    .font(.system(size: 10.5))
            }
        }
        .onAppear { refreshCleanup() }
        .onChange(of: cleanupDays) { _, _ in confirmCleanup = false; refreshCleanup() }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(Theme.sans(12))
    }

    private func refreshCleanup() {
        let sessions = store.snapshot.sessions
        let days = cleanupDays
        DispatchQueue.global(qos: .userInitiated).async {
            let c = SessionFiles.older(than: days, in: sessions)
            let total = SessionFiles.totalSize()
            DispatchQueue.main.async { candidates = c; totalSize = total }
        }
    }
}
