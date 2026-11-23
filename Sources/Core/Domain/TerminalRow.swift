import Foundation

/// One line of a terminal screen as the app draws it: text, or a horizontal rule.
enum TerminalRow: Equatable { case text(String), rule }
