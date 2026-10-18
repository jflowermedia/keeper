import SwiftUI
import AppKit

// MARK: - A key and its modifiers

/// One keystroke. `key` is a single lowercase character for an ordinary key, or one of the
/// names below for the ones that aren't characters.
///
/// Stored in UserDefaults as JSON, so it has to survive a version that adds a field — see
/// the lenient decoder in the extension.
struct KeyCombo: Codable, Hashable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    /// The names used for keys that aren't a character, and how to show each one.
    static let specialNames: [String: String] = [
        "space": "Space",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "return": "Return", "tab": "Tab", "escape": "Esc", "delete": "Delete",
        "home": "Home", "end": "End", "pageup": "Page Up", "pagedown": "Page Down"
    ]

    /// How it reads in the interface: "⇧⌘K", "Space", "↑".
    var display: String {
        // Apple's order, which is what people expect to see in a menu.
        var out = ""
        if control { out += "⌃" }
        if option  { out += "⌥" }
        if shift   { out += "⇧" }
        if command { out += "⌘" }
        return out + (Self.specialNames[key] ?? key.uppercased())
    }

    var hasModifier: Bool { command || shift || option || control }
}

extension KeyCombo {
    /// Hand-written so a combo written by an older version — or a newer one with a field this
    /// build doesn't know — still decodes. The house rule for stored types, applied here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = (try c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        command = (try c.decodeIfPresent(Bool.self, forKey: .command)) ?? false
        shift = (try c.decodeIfPresent(Bool.self, forKey: .shift)) ?? false
        option = (try c.decodeIfPresent(Bool.self, forKey: .option)) ?? false
        control = (try c.decodeIfPresent(Bool.self, forKey: .control)) ?? false
    }

    /// The name this build uses for whatever was pressed, or nil for a key it can't bind —
    /// modifiers on their own, and anything that isn't one character.
    ///
    /// `charactersIgnoringModifiers` still applies Shift, so Shift+3 arrives as "#". Letters
    /// come back lowercased and the punctuation is mapped back to the key it sits on, which
    /// is a US layout assumption; on another layout the letters still work, which is what
    /// nearly every shortcut uses.
    static func name(for event: NSEvent) -> String? {
        guard let raw = event.charactersIgnoringModifiers, raw.count == 1,
              let character = raw.unicodeScalars.first
        else { return nil }

        switch character {
        case " ":        return "space"
        case "\r", "\u{3}": return "return"      // Return, and the numeric pad's Enter
        case "\t", "\u{19}": return "tab"        // Tab, and Shift-Tab's back-tab
        case "\u{1B}":   return "escape"
        case "\u{7F}", "\u{8}": return "delete"
        default: break
        }

        // AppKit's private-use block for the keys that aren't characters: NSUpArrowFunctionKey
        // and the rest. Written as literals rather than the constants because those are
        // imported from an anonymous C enum and their Swift type isn't worth depending on;
        // the values themselves have been fixed since NeXTSTEP.
        switch character.value {
        case 0xF700: return "up"
        case 0xF701: return "down"
        case 0xF702: return "left"
        case 0xF703: return "right"
        case 0xF729: return "home"
        case 0xF72B: return "end"
        case 0xF72C: return "pageup"
        case 0xF72D: return "pagedown"
        default: break
        }

        // A function key or anything else outside the printable range can't be shown or
        // matched reliably, so it isn't offered.
        guard character.value >= 0x20, character.value < 0x7F else { return nil }

        let lowered = raw.lowercased()
        if event.modifierFlags.contains(.shift), let base = shiftedBack[lowered] {
            return base
        }
        return lowered
    }

    private static let shiftedBack: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
        "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    /// Built from a key press, for the recorder in the shortcuts sheet.
    init?(event: NSEvent) {
        guard let name = Self.name(for: event) else { return nil }
        let flags = event.modifierFlags
        self.init(key: name,
                  command: flags.contains(.command),
                  shift: flags.contains(.shift),
                  option: flags.contains(.option),
                  control: flags.contains(.control))
    }

    // MARK: Into SwiftUI

    var equivalent: KeyEquivalent {
        switch key {
        case "space":    return .space
        case "up":       return .upArrow
        case "down":     return .downArrow
        case "left":     return .leftArrow
        case "right":    return .rightArrow
        case "return":   return .return
        case "tab":      return .tab
        case "escape":   return .escape
        case "delete":   return .delete
        case "home":     return .home
        case "end":      return .end
        case "pageup":   return .pageUp
        case "pagedown": return .pageDown
        default:
            guard let character = key.first else { return .space }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if command { out.insert(.command) }
        if shift   { out.insert(.shift) }
        if option  { out.insert(.option) }
        if control { out.insert(.control) }
        return out
    }
}

// MARK: - What can be bound

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    // Reviewing: one press, no modifiers, caught by the event monitor in `Playback`.
    case playPause, shuttleBack, shuttleForward, previousClip, nextClip
    // Menu commands: always with ⌘, set on the menu item itself.
    case chooseFolder, rescan, export, verify, importRoster, editRosters
    case toggleKeep, markKeep, markNotKeep
    case fullScreen, taggingPanel, keyboardFlow, debugLog

    var id: String { rawValue }

    enum Group { case review, menu }

    var group: Group {
        switch self {
        case .playPause, .shuttleBack, .shuttleForward, .previousClip, .nextClip:
            return .review
        default:
            return .menu
        }
    }

    var title: String {
        switch self {
        case .playPause:       return "Play / pause"
        case .shuttleBack:     return "Shuttle back"
        case .shuttleForward:  return "Shuttle forward"
        case .previousClip:    return "Previous clip"
        case .nextClip:        return "Next clip"
        case .chooseFolder:    return "Choose Folder…"
        case .rescan:          return "Rescan"
        case .export:          return "Export…"
        case .verify:          return "Check the Card Copied…"
        case .importRoster:    return "Import Roster CSV…"
        case .editRosters:     return "Edit Rosters…"
        case .toggleKeep:      return "Toggle KEEP on previewed clip"
        case .markKeep:        return "Mark selection KEEP"
        case .markNotKeep:     return "Mark selection NOT KEEP"
        case .fullScreen:      return "Full screen preview"
        case .taggingPanel:    return "Tagging panel"
        case .keyboardFlow:    return "Keyboard tagging"
        case .debugLog:        return "Debug log"
        }
    }

    /// The title as it reads inside a sentence: lowercased, and without the trailing ellipsis
    /// a menu item carries. "⌘S is already export." rather than "already export….".
    var inSentence: String {
        let base = title.hasSuffix("…") ? String(title.dropLast()) : title
        return base.lowercased()
    }

    /// Only the review keys take a second key, which is how Space and 2 both play out of the box.
    var takesSecondKey: Bool { group == .review }
}

// MARK: - The store

/// Which key does what, and the rules about changing it.
///
/// Not `@MainActor`, because the event monitor that reads it isn't either — same as
/// `Playback` and `TagLibrary`. Everything here runs on the main thread in practice.
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    @Published private(set) var bindings: [ShortcutAction: [KeyCombo]]

    private static let storeKey = "shortcuts"

    static let defaults: [ShortcutAction: [KeyCombo]] = [
        .playPause:      [KeyCombo(key: "space"), KeyCombo(key: "2")],
        .shuttleBack:    [KeyCombo(key: "1")],
        .shuttleForward: [KeyCombo(key: "3")],
        .previousClip:   [KeyCombo(key: "up")],
        .nextClip:       [KeyCombo(key: "down")],

        .chooseFolder:   [KeyCombo(key: "o", command: true)],
        .rescan:         [KeyCombo(key: "r", command: true)],
        .export:         [KeyCombo(key: "s", command: true)],
        .verify:         [KeyCombo(key: "v", command: true, shift: true)],
        .importRoster:   [KeyCombo(key: "i", command: true)],
        .editRosters:    [KeyCombo(key: "r", command: true, shift: true)],
        .toggleKeep:     [KeyCombo(key: "k", command: true)],
        .markKeep:       [KeyCombo(key: "k", command: true, shift: true)],
        .markNotKeep:    [KeyCombo(key: "k", command: true, option: true)],
        .fullScreen:     [KeyCombo(key: "f", command: true)],
        .taggingPanel:   [KeyCombo(key: "e", command: true)],
        .keyboardFlow:   [KeyCombo(key: "t", command: true, shift: true)],
        .debugLog:       [KeyCombo(key: "d", command: true)]
    ]

    private init() {
        bindings = Self.defaults
        load()
    }

    // MARK: Reading

    /// The main key for an action. Never nil: a missing or emptied binding falls back to the
    /// default, so a menu item can't end up with no key at all.
    func combo(_ action: ShortcutAction) -> KeyCombo {
        if let first = bindings[action]?.first { return first }
        return Self.defaults[action]?.first ?? KeyCombo(key: "space")
    }

    func combos(_ action: ShortcutAction) -> [KeyCombo] {
        let set = bindings[action] ?? []
        return set.isEmpty ? (Self.defaults[action] ?? []) : set
    }

    func equivalent(_ action: ShortcutAction) -> KeyEquivalent { combo(action).equivalent }
    func modifiers(_ action: ShortcutAction) -> EventModifiers { combo(action).eventModifiers }

    /// For help text and the placeholder in the preview pane: "Space or 2".
    func display(_ action: ShortcutAction) -> String {
        let all = combos(action)
        guard !all.isEmpty else { return "—" }
        return all.map(\.display).joined(separator: " or ")
    }

    /// Which review action a bare key press means, if any. The monitor has already
    /// established there are no modifiers held.
    func reviewAction(forKey key: String) -> ShortcutAction? {
        for action in ShortcutAction.allCases where action.group == .review {
            if combos(action).contains(where: { $0.key == key && !$0.hasModifier }) {
                return action
            }
        }
        return nil
    }

    var isCustomised: Bool {
        for action in ShortcutAction.allCases {
            if combos(action) != (Self.defaults[action] ?? []) { return true }
        }
        return false
    }

    // MARK: Changing

    /// Binds `combo` to an action's first or second key.
    ///
    /// Whatever held that key gives it up. Where both are the main key of their group the two
    /// swap, so rearranging two shortcuts can't leave either of them unreachable — which for a
    /// menu command would mean a key that no longer does anything and no way to get it back
    /// except Reset.
    ///
    /// Returns a line to show the user, or nil when there's nothing worth saying.
    @discardableResult
    func assign(_ combo: KeyCombo, to action: ShortcutAction, slot: Int) -> String? {
        if let refusal = Self.refusal(for: combo, group: action.group) { return refusal }

        var map = Self.filled(bindings)
        let current = map[action] ?? []

        if let index = current.firstIndex(of: combo) {
            return index == slot ? nil : "\(combo.display) is already \(action.inSentence)."
        }

        let outgoing: KeyCombo? = slot < current.count ? current[slot] : nil

        // A combo can only be in one place, so there's at most one other holder.
        var holder: (action: ShortcutAction, index: Int)?
        for (other, list) in map where other != action {
            if let index = list.firstIndex(of: combo) {
                holder = (other, index)
                break
            }
        }

        var note: String?
        if let holder {
            var theirs = map[holder.action] ?? []
            if let outgoing, holder.index == 0, slot == 0, holder.action.group == action.group {
                theirs[holder.index] = outgoing
                note = "\(combo.display) was \(holder.action.inSentence) — "
                     + "the two have swapped, so that's now \(outgoing.display)."
            } else {
                theirs.remove(at: holder.index)
                if theirs.isEmpty {
                    return "\(combo.display) is the only key for \(holder.action.inSentence). "
                         + "Give that one another key first."
                }
                note = "\(combo.display) was \(holder.action.inSentence), "
                     + "and has been taken off it."
            }
            map[holder.action] = theirs
        }

        var mine = current
        if slot < mine.count {
            mine[slot] = combo
        } else {
            mine.append(combo)
        }
        map[action] = mine

        bindings = map
        persist()
        return note
    }

    /// Drops an action's second key. The first can only ever be replaced, never removed.
    func clearSecond(_ action: ShortcutAction) {
        var map = Self.filled(bindings)
        guard let mine = map[action], let first = mine.first, mine.count > 1 else { return }
        map[action] = [first]
        bindings = map
        persist()
    }

    func reset(_ action: ShortcutAction) {
        var map = Self.filled(bindings)
        map[action] = Self.defaults[action] ?? []
        // Putting a default back can collide with something that was moved onto it. The
        // other one loses the key rather than the reset failing, which is what Reset means —
        // and if that empties it, it gets its own default back too.
        if let mine = map[action] {
            let before = map        // explicit snapshot: the loop writes to `map`
            for (other, list) in before where other != action {
                let kept = list.filter { !mine.contains($0) }
                if kept.isEmpty {
                    map[other] = Self.defaults[other] ?? list
                } else if kept.count != list.count {
                    map[other] = kept
                }
            }
        }
        bindings = map
        persist()
    }

    func resetAll() {
        bindings = Self.defaults
        persist()
    }

    // MARK: Rules

    /// Letters macOS or the window itself has a claim on. Only as plain ⌘ — ⌘⇧Q and the rest
    /// are free, which is why Keeper's own ⌘⇧V and ⌘⇧R are allowed.
    private static let systemReserved: Set<String> = [
        "q", "w", "h", "m", "n", "a", "c", "v", "x", "z", "p", ",", "`"
    ]

    private static func refusal(for combo: KeyCombo, group: ShortcutAction.Group) -> String? {
        guard !combo.key.isEmpty else { return "That key can't be used." }

        switch group {
        case .review:
            guard !combo.hasModifier else {
                return "A review key is a single press with no modifier, so it can be worked "
                     + "one-handed. Use the menu commands below for ⌘ shortcuts."
            }
            if ["escape", "return", "tab"].contains(combo.key) {
                return "\(combo.display) is needed for getting around the window."
            }
        case .menu:
            guard combo.command else {
                return "A menu command needs ⌘, or it would fire while you were typing."
            }
            if !combo.shift, !combo.option, !combo.control,
               systemReserved.contains(combo.key) {
                return "\(combo.display) belongs to macOS. Try it with ⇧ or ⌥."
            }
        }
        return nil
    }

    // MARK: Persistence

    /// Any action the stored file didn't carry — one added in a later version — takes its
    /// default, so the map handed around is always complete.
    private static func filled(_ map: [ShortcutAction: [KeyCombo]]) -> [ShortcutAction: [KeyCombo]] {
        var out = map
        for action in ShortcutAction.allCases where (out[action] ?? []).isEmpty {
            out[action] = defaults[action] ?? []
        }
        return out
    }

    /// Keyed by the action's raw name rather than the action itself: a dictionary with an enum
    /// key encodes as a flat array of alternating keys and values, and one unrecognised name in
    /// it — an action a later version added — throws the whole file away. Strings let the
    /// unknown ones be skipped instead.
    private func persist() {
        var flat: [String: [KeyCombo]] = [:]
        for (action, list) in bindings { flat[action.rawValue] = list }
        guard let data = try? JSONEncoder().encode(flat) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let flat = try? JSONDecoder().decode([String: [KeyCombo]].self, from: data)
        else { return }

        var stored: [ShortcutAction: [KeyCombo]] = [:]
        for (name, list) in flat {
            guard let action = ShortcutAction(rawValue: name) else { continue }
            // Anything that breaks the rules for its group — a hand-edited plist, or a rule
            // a later version tightened — is dropped rather than left bound to a key that
            // can never match. `filled` then puts the default back.
            stored[action] = list.filter { Self.refusal(for: $0, group: action.group) == nil }
        }
        // Nothing here is worth protecting the way the tag library is: a set of shortcuts
        // that won't decode is replaced by the defaults rather than reported.
        bindings = Self.filled(stored)
    }
}
