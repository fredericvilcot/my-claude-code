import Foundation

/// Demo mode (`MCC_DEMO=1`, with `CFFIXED_USER_HOME` pointing at a fake home): used to take the README screenshots
/// from made-up data (see docs/demo). The app then never runs `claude` itself, so no real account data can appear.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["MCC_DEMO"] != nil
}
