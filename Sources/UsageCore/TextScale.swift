import Foundation

/// Size of the open menu's content, in 10% steps. The item in the menu bar
/// itself always keeps the system size.
public enum TextScale {
    public static let steps = Array(stride(from: 80, through: 150, by: 10))
    public static let defaultPercent = 100
    public static let defaultsKey = "menuTextScalePercent"

    /// Any stored value, snapped to the nearest allowed step.
    public static func sanitize(_ percent: Int?) -> Int {
        guard let percent else { return defaultPercent }
        return steps.min { abs($0 - percent) < abs($1 - percent) } ?? defaultPercent
    }

    /// The multiplier for a stored percentage: 1.15 for 115%.
    public static func factor(_ percent: Int?) -> Double {
        Double(sanitize(percent)) / 100
    }
}
