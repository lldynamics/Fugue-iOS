import Foundation

/// Single source of truth for "how many history messages to send", shared by the assistant
/// editor and the per-conversation settings so both always offer the same values.
enum ContextLimitOptions {
    /// 0 means "send the whole history".
    static let standardValues = [4, 10, 20, 50, 0]

    /// Standard values plus `current` if it is non-standard (e.g. 8 or 24 saved by an older
    /// version), so a Picker never ends up with a selection that has no matching tag.
    static func values(including current: Int) -> [Int] {
        guard !standardValues.contains(current) else { return standardValues }
        let limited = (standardValues.filter { $0 > 0 } + [current]).sorted()
        return limited + [0]
    }

    static func label(for value: Int) -> String {
        value == 0 ? String(localized: "全部历史") : String(localized: "最近 \(value) 条")
    }
}
