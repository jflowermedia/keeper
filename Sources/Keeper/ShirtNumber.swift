import Foundation

/// Shirt numbers as they're worn, sorted and typed.
///
/// A player's id is their team and number, so two can't hold the same one. Where a list has
/// them share, each gets a letter, the way a scoresheet would: 15 and 15b. The letter is
/// Keeper's, so it's shown on the bench and left out of filenames.
enum ShirtNumber {

    /// Whether the number carries one of Keeper's letters.
    static func isLettered(_ number: String) -> Bool {
        number.range(of: "^[0-9]+[a-z]$", options: .regularExpression) != nil
    }

    /// What's on the shirt.
    static func worn(_ number: String) -> String {
        isLettered(number) ? String(number.dropLast()) : number
    }

    /// Three digits isn't a shirt. Feeds use them, and 999, for players with none yet.
    static func isPlaceholder(_ number: String) -> Bool {
        number.count > 2 && number.allSatisfy(\.isNumber)
    }

    /// From the digits on, so a number you've typed as (15) is found by 15 too.
    static func matches(_ number: String, typed: String) -> Bool {
        number.hasPrefix(typed) || number.drop { !$0.isNumber }.hasPrefix(typed)
    }

    /// 15, 15b and (15) sit together, plain one first.
    static func comesBefore(_ a: Player, _ b: Player) -> Bool {
        (value(a.number), a.number.count, a.number, a.name)
            < (value(b.number), b.number.count, b.number, b.name)
    }

    private static func value(_ number: String) -> Int {
        Int(number.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? Int.max
    }

    /// The first letter free on this number. Starts at b when someone has the number plain:
    /// 15 and 15b. With nobody's claim clear, 15a and 15b, so neither looks like the real one.
    static func lettered(_ number: String, taken: Set<String>, plainIsHeld: Bool) -> String? {
        "abcdefghijklmnopqrstuvwxyz".dropFirst(plainIsHeld ? 1 : 0)
            .map { "\(number)\($0)" }
            .first { !taken.contains($0) }
    }
}
