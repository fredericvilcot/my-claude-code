import Foundation

/// Time-series point used by the shared Sparkline component.
struct Sample: Identifiable {
    let id: Int
    let date: Date
    let value: Double
}
