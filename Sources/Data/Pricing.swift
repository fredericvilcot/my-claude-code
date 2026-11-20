import Foundation

/// Public Claude API prices in USD per million tokens (input, output, cache read).
/// Cache writes cost 1.25x input (5-minute TTL) or 2x input (1-hour TTL).
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
}

enum Pricing {
    /// Date of the price list embedded below.
    static let asOf = "3 novembre 2026"

    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-2", ModelPrice(input: 8, output: 40, cacheRead: 0.20)),
        ("claude-mythos-5-2", ModelPrice(input: 8, output: 40, cacheRead: 0.20)),
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1.00)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1.00)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.10)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4-6", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5-5", ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5, cacheRead: 0.10)),
    ]

    /// Family-level fallback for models missing from the table (cost flagged as estimated).
    private static let families: [(String, ModelPrice)] = [
        ("fable", ModelPrice(input: 10, output: 50, cacheRead: 1.00)),
        ("mythos", ModelPrice(input: 10, output: 50, cacheRead: 1.00)),
        ("opus", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("sonnet", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("haiku", ModelPrice(input: 1, output: 5, cacheRead: 0.10)),
    ]

    static func isKnown(_ model: String) -> Bool {
        table.contains { model.hasPrefix($0.prefix) }
    }

    static func price(for model: String, fast: Bool, promptTokens: Int) -> ModelPrice {
        var p = table.first { model.hasPrefix($0.prefix) }?.price
            ?? families.first { model.contains($0.0) }?.1
            ?? ModelPrice(input: 5, output: 25, cacheRead: 0.50)
        // Claude Haiku 5.5: higher tier above 100K prompt tokens.
        if model.hasPrefix("claude-haiku-5-5"), promptTokens > 100_000 {
            p = ModelPrice(input: 0.50, output: 2.50, cacheRead: 0.05)
        }
        // Fast mode doubles the per-token price.
        if fast { p = ModelPrice(input: p.input * 2, output: p.output * 2, cacheRead: p.cacheRead * 2) }
        return p
    }

    struct Breakdown {
        var input = 0.0, output = 0.0, write = 0.0, read = 0.0
        /// Billed by Claude Code but absent from transcripts (auto-mode classifier, background tasks).
        var other = 0.0
        var total: Double { input + output + write + read + other }
        static func + (a: Breakdown, b: Breakdown) -> Breakdown {
            Breakdown(input: a.input + b.input, output: a.output + b.output, write: a.write + b.write, read: a.read + b.read,
                      other: a.other + b.other)
        }
    }

    static func cost(model: String, fast: Bool, input: Int, output: Int, write5m: Int, write1h: Int, read: Int) -> Breakdown {
        let p = price(for: model, fast: fast, promptTokens: input + write5m + write1h + read)
        let m = 1_000_000.0
        return Breakdown(input: Double(input) * p.input / m,
                         output: Double(output) * p.output / m,
                         write: (Double(write5m) * 1.25 + Double(write1h) * 2) * p.input / m,
                         read: Double(read) * p.cacheRead / m)
    }

    /// What cache reads would have cost if billed as regular input.
    static func cacheSavings(model: String, fast: Bool, read: Int) -> Double {
        let p = price(for: model, fast: fast, promptTokens: read)
        return Double(read) * (p.input - p.cacheRead) / 1_000_000
    }
}
