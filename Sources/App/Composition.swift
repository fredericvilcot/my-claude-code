import Foundation

/// Composition root: the only place where adapters are plugged into the core's ports.
@MainActor
enum Composition {
    static func install() {
        let ports = HandOverPorts(typing: TerminalTyping(), state: ClaudeSessionState(), launcher: ITermLaunching(),
                                  retirement: SessionRetirement(), notes: SessionNotes(), presenter: AppPresenter())
        Compactor.shared = Compactor(ports: ports)
        Restarter.shared = Restarter(ports: ports)
    }
}
