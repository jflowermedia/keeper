import SwiftUI

// MARK: - Catppuccin

/// The look of the app: macOS's own, or one of Catppuccin's four flavours
/// (https://catppuccin.com/palette, MIT). Stored in UserDefaults, not the library — it's a
/// preference of this Mac, not something a card or a roster carries.
enum ThemeFlavor: String, CaseIterable, Identifiable {
    case system, latte, frappe, macchiato, mocha

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:    return "System"
        case .latte:     return "Latte"
        case .frappe:    return "Frappé"
        case .macchiato: return "Macchiato"
        case .mocha:     return "Mocha"
        }
    }

    var palette: Palette? {
        switch self {
        case .system:    return nil
        case .latte:     return .latte
        case .frappe:    return .frappe
        case .macchiato: return .macchiato
        case .mocha:     return .mocha
        }
    }

    /// Latte is the light one. Native controls only get light or dark, so this is what
    /// keeps a dropdown from sitting pale on Mocha's base.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .latte:  return .light
        default:      return .dark
        }
    }

    static let storageKey = "theme"
    static var current: ThemeFlavor { ThemeColors.shared.flavor }
    fileprivate static var stored: ThemeFlavor {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ThemeFlavor.init) ?? .system
    }
}

/// Catppuccin's fourteen accents. Only used with a flavour: under System the accent is the
/// one set in System Settings.
enum ThemeAccent: String, CaseIterable, Identifiable {
    case rosewater, flamingo, pink, mauve, red, maroon, peach
    case yellow, green, teal, sky, sapphire, blue, lavender

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    static let storageKey = "themeAccent"
    /// Mauve, because it's the closest to the purple Keeper has been wearing.
    static var current: ThemeAccent { ThemeColors.shared.accent }
    fileprivate static var stored: ThemeAccent {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ThemeAccent.init) ?? .mauve
    }
}

struct Palette {
    let accents: [ThemeAccent: Color]
    let text, subtext0, overlay2, surface0, base, mantle, crust: Color

    var green: Color { accents[.green]! }
    var yellow: Color { accents[.yellow]! }
    var red: Color { accents[.red]! }
    var peach: Color { accents[.peach]! }

    /// The 26 hex values in Catppuccin's order, so each flavour reads straight off the
    /// palette page and a typo is easy to spot against it.
    private init(_ hex: [UInt32]) {
        precondition(hex.count == 26)
        let c = hex.map(Color.init(hex:))
        var accents: [ThemeAccent: Color] = [:]
        for (i, accent) in ThemeAccent.allCases.enumerated() { accents[accent] = c[i] }
        self.accents = accents
        // 14 text, 15 subtext1, 16 subtext0, 17 overlay2, … 22 surface0, 23 base, 24 mantle,
        // 25 crust.
        text = c[14]; subtext0 = c[16]; overlay2 = c[17]; surface0 = c[22]
        base = c[23]; mantle = c[24]; crust = c[25]
    }

    static let latte = Palette([
        0xdc8a78, 0xdd7878, 0xea76cb, 0x8839ef, 0xd20f39, 0xe64553, 0xfe640b,
        0xdf8e1d, 0x40a02b, 0x179299, 0x04a5e5, 0x209fb5, 0x1e66f5, 0x7287fd,
        0x4c4f69, 0x5c5f77, 0x6c6f85, 0x7c7f93, 0x8c8fa1, 0x9ca0b0,
        0xacb0be, 0xbcc0cc, 0xccd0da, 0xeff1f5, 0xe6e9ef, 0xdce0e8,
    ])
    static let frappe = Palette([
        0xf2d5cf, 0xeebebe, 0xf4b8e4, 0xca9ee6, 0xe78284, 0xea999c, 0xef9f76,
        0xe5c890, 0xa6d189, 0x81c8be, 0x99d1db, 0x85c1dc, 0x8caaee, 0xbabbf1,
        0xc6d0f5, 0xb5bfe2, 0xa5adce, 0x949cbb, 0x838ba7, 0x737994,
        0x626880, 0x51576d, 0x414559, 0x303446, 0x292c3c, 0x232634,
    ])
    static let macchiato = Palette([
        0xf4dbd6, 0xf0c6c6, 0xf5bde6, 0xc6a0f6, 0xed8796, 0xee99a0, 0xf5a97f,
        0xeed49f, 0xa6da95, 0x8bd5ca, 0x91d7e3, 0x7dc4e4, 0x8aadf4, 0xb7bdf8,
        0xcad3f5, 0xb8c0e0, 0xa5adcb, 0x939ab7, 0x8087a2, 0x6e738d,
        0x5b6078, 0x494d64, 0x363a4f, 0x24273a, 0x1e2030, 0x181926,
    ])
    static let mocha = Palette([
        0xf5e0dc, 0xf2cdcd, 0xf5c2e7, 0xcba6f7, 0xf38ba8, 0xeba0ac, 0xfab387,
        0xf9e2af, 0xa6e3a1, 0x94e2d5, 0x89dceb, 0x74c7ec, 0x89b4fa, 0xb4befe,
        0xcdd6f4, 0xbac2de, 0xa6adc8, 0x9399b2, 0x7f849c, 0x6c7086,
        0x585b70, 0x45475a, 0x313244, 0x1e1e2e, 0x181825, 0x11111b,
    ])
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - What the views use

/// The theme's colours, resolved once and kept until a setting changes.
///
/// Every chip, badge and key asks for its colour as it draws, and moving down one clip redraws
/// the whole list. Reading UserDefaults on each of those asks made the app noticeably slower
/// the day themes went in; this is the fix. Main thread only, like `FlowKeyState`.
final class ThemeColors: NSObject {
    static let shared = ThemeColors()

    private(set) var flavor = ThemeFlavor.system
    private(set) var accent = ThemeAccent.mauve
    private(set) var accentColor = Color.accentColor
    private(set) var green = Color.green
    private(set) var yellow = Color.yellow
    private(set) var red = Color.red
    private(set) var orange = Color.orange
    private(set) var secondary = Color.secondary
    private(set) var text = Color.primary

    private override init() {
        super.init()
        reload()
        // Observing the two keys rather than `didChangeNotification`, which only fires for
        // writes made inside the app: a theme set any other way left the window repainted by
        // `@AppStorage` but every chip still in the old theme's colours. KVO is also what
        // `@AppStorage` itself uses, and it reports synchronously, so the cache is current
        // before the `.id` change that rebuilds the window.
        for key in [ThemeFlavor.storageKey, ThemeAccent.storageKey] {
            UserDefaults.standard.addObserver(self, forKeyPath: key, context: nil)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if Thread.isMainThread {
            reload()
        } else {
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }

    private func reload() {
        flavor = ThemeFlavor.stored
        accent = ThemeAccent.stored
        let palette = flavor.palette
        accentColor = palette?.accents[accent] ?? .accentColor
        green = palette?.green ?? .green
        yellow = palette?.yellow ?? .yellow
        red = palette?.red ?? .red
        orange = palette?.peach ?? .orange
        secondary = palette?.subtext0 ?? .secondary
        text = palette?.text ?? .primary
    }
}

/// Every colour the app picks for itself goes through these, so a theme is one switch rather
/// than a search through every view. Under System each is exactly what was there before.
///
/// On `ShapeStyle` where `Self == Color` so `.foregroundStyle(.keeperOrange)` reads the same
/// as `Color.keeperOrange`. Read at draw time; the root view is rebuilt when the theme
/// changes, which is what makes that enough.
extension ShapeStyle where Self == Color {
    static var keeperAccent: Color { ThemeColors.shared.accentColor }
    static var keeperGreen: Color { ThemeColors.shared.green }
    static var keeperYellow: Color { ThemeColors.shared.yellow }
    static var keeperRed: Color { ThemeColors.shared.red }
    static var keeperOrange: Color { ThemeColors.shared.orange }
    /// Quiet text and the faint fills behind chips. macOS uses one grey for both, and so does
    /// this: subtext0 reads as text and washes to a surface at the low opacities the fills use.
    static var keeperSecondary: Color { ThemeColors.shared.secondary }
    static var keeperText: Color { ThemeColors.shared.text }
}

extension View {
    /// The window-level half: background, light or dark for the native controls, their tint,
    /// and the text colour `.secondary` and `.tertiary` are derived from. On the main window
    /// and on every sheet, since a sheet is a window of its own.
    func keeperThemed() -> some View { modifier(KeeperThemed()) }
}

private struct KeeperThemed: ViewModifier {
    @AppStorage(ThemeFlavor.storageKey) private var flavor = ThemeFlavor.system.rawValue
    @AppStorage(ThemeAccent.storageKey) private var accent = ThemeAccent.mauve.rawValue

    func body(content: Content) -> some View {
        let theme = ThemeFlavor(rawValue: flavor) ?? .system
        Group {
            if let palette = theme.palette {
                content
                    .foregroundStyle(palette.text)
                    // Reaches SwiftUI's own controls. AppKit-drawn ones — the toolbar toggles,
                    // dropdown arrows, a default button — keep the accent from System
                    // Settings; `.accentColor` was tried and doesn't reach them either.
                    .tint(Color.keeperAccent)
                    // Lists and text editors paint their own background over the window's;
                    // hidden, the palette shows through them too.
                    .scrollContentBackground(.hidden)
                    .background(palette.base)
            } else {
                content
            }
        }
        // The app's appearance rather than `preferredColorScheme`, which on macOS doesn't
        // reliably let go when it's set back to nil — System would stay stuck on dark.
        .onAppear { Self.applyAppearance(theme) }
        .onChange(of: flavor) { _ in Self.applyAppearance(ThemeFlavor.current) }
    }

    private static func applyAppearance(_ theme: ThemeFlavor) {
        switch theme.colorScheme {
        case .light?: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark?:  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }
}
