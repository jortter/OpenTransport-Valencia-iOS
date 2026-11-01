import Foundation

public enum Favorites {
    /// The saved keys after the user reordered the ones on screen. `shown` is
    /// the visible keys (a network filter may hide some) in their new order;
    /// they fill the slots they took before, and hidden keys stay put.
    public static func reorder(_ all: [String], shown: [String]) -> [String] {
        let visible = Set(shown)
        var next = shown[...]
        return all.map { key in visible.contains(key) ? next.popFirst() ?? key : key }
    }
}
