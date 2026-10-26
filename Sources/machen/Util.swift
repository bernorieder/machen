import SwiftUI
import Security

/// Date conversions between Google's wire formats and local dates.
enum GDate {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDateTime(_ s: String) -> Date? {
        iso.date(from: s) ?? isoFractional.date(from: s)
    }

    /// Parses the "yyyy-MM-dd" prefix as a local calendar day (all-day events, task due dates).
    static func parseDay(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    static func dateTimeString(_ d: Date) -> String {
        iso.string(from: d)
    }

    /// Google Tasks stores only the date part of `due`, always as midnight UTC.
    static func taskDueString(_ d: Date) -> String {
        dayString(d) + "T00:00:00.000Z"
    }
}

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }
}

extension String {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    var formEscaped: String {
        addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? self
    }

    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: Self.unreserved.union(CharacterSet(charactersIn: "@"))) ?? self
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

enum Keychain {
    private static let service = "local.machen"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Updates the item in place, which any build may do silently. Deleting and re-adding it would
    /// need the item's owner permission, which always asks. (An item belongs to the app that created
    /// it; one created by a Developer ID build is tied to the team, so later builds can read it.)
    static func set(_ data: Data, for account: String) {
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    /// Empties the item instead of deleting it, which would ask for permission (see `set`).
    static func clear(_ account: String) {
        SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: Data()] as CFDictionary)
    }
}

/// Drop-in for `@State`. Recent SDKs implement `@State` as a macro whose plugin ships only with
/// full Xcode, so this plain property wrapper keeps the app buildable with Command Line Tools.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let state: State<Value>

    init(wrappedValue: Value) {
        state = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}

/// Google Tasks lists have no color of their own, so the app assigns one (changeable in Settings).
enum ListPalette {
    static let colors: [(name: String, hex: String)] = [
        ("Peacock", "#039BE5"), ("Basil", "#0B8043"), ("Tangerine", "#F4511E"), ("Grape", "#8E24AA"),
        ("Banana", "#F6BF26"), ("Tomato", "#D50000"), ("Blueberry", "#3F51B5"), ("Sage", "#33B679"),
        ("Flamingo", "#E67C73"), ("Lavender", "#7986CB"), ("Graphite", "#616161"),
    ]

    private static var swatches: [String: NSImage] = [:]

    /// A non-template colour dot; menus on macOS drop the colour of tinted SF Symbols and shapes.
    /// Made once per colour, since Settings shows the whole palette for every list.
    static func swatch(_ hex: String) -> NSImage {
        if let image = swatches[hex] { return image }
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor(Color(hex: hex) ?? .gray).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        swatches[hex] = image
        return image
    }
}

/// Which open tasks the agenda lists, chosen in Settings.
enum TaskFilter: String, CaseIterable, Identifiable {
    case all, dueOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .dueOnly: "Due date only"
        }
    }

    /// The option after this one, for cycling with a click.
    var next: TaskFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Icons offered for the menu bar: SF Symbols, plus the bundled Font Awesome fist.
enum MenuBarIcon {
    /// Choice id for Font Awesome Free's hand-fist (CC BY 4.0), bundled as hand-fist.svg.
    static let fist = "fist"

    static let choices: [(name: String, symbol: String)] = [
        ("Fist", fist),
        ("Calendar", "calendar"),
        ("Calendar with clock", "calendar.badge.clock"),
        ("Checklist", "checklist"),
        ("Check mark", "checkmark.circle"),
        ("List", "list.bullet.rectangle"),
        ("Hammer", "hammer"),
        ("Sun", "sun.max"),
        ("Bolt", "bolt"),
    ]

    /// The fist as a template image sized for the menu bar, or nil when the SVG isn't bundled
    /// (for example when running the bare executable from `swift run`).
    private static let fistImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "hand-fist", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        // A solid glyph looks heavier than the outline SF Symbols, so it's a bit smaller than them
        let height = Layout.MenuBar.fistHeight
        image.size = NSSize(width: height * image.size.width / image.size.height, height: height)
        image.isTemplate = true
        return image
    }()

    @ViewBuilder
    static func image(_ id: String) -> some View {
        if id == fist {
            if let fistImage {
                Image(nsImage: fistImage)
            } else {
                Image(systemName: "hand.raised.fill")
            }
        } else {
            Image(systemName: id)
        }
    }
}

/// How multi-day events appear in the agenda, chosen in Settings.
enum MultiDayMode: String, CaseIterable, Identifiable {
    case everyDay, todayAndStart, exclude

    var id: String { rawValue }
    var label: String {
        switch self {
        case .everyDay: "Show on every day"
        case .todayAndStart: "Show on today and start day"
        case .exclude: "Exclude"
        }
    }
}

/// Row spacing chosen in Settings; controls row padding and line height in the agenda.
enum RowDensity: String, CaseIterable, Identifiable {
    case compact, standard, roomy

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var rowPadding: CGFloat {
        switch self {
        case .compact: Layout.Spacing.RowPadding.compact
        case .standard: Layout.Spacing.RowPadding.standard
        case .roomy: Layout.Spacing.RowPadding.roomy
        }
    }

    /// Gap between the title, notes and date lines of one row.
    var lineGap: CGFloat {
        switch self {
        case .compact: Layout.Spacing.LineGap.compact
        case .standard: Layout.Spacing.LineGap.standard
        case .roomy: Layout.Spacing.LineGap.roomy
        }
    }

    /// Extra leading for text that wraps onto several lines.
    var lineSpacing: CGFloat {
        switch self {
        case .compact: Layout.Spacing.LineSpacing.compact
        case .standard: Layout.Spacing.LineSpacing.standard
        case .roomy: Layout.Spacing.LineSpacing.roomy
        }
    }
}

private struct RowDensityKey: EnvironmentKey {
    static let defaultValue = RowDensity.standard
}

extension EnvironmentValues {
    var rowDensity: RowDensity {
        get { self[RowDensityKey.self] }
        set { self[RowDensityKey.self] = newValue }
    }
}

/// A text size step chosen in Settings. Medium keeps the system sizes.
enum TextSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge

    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }

    private var scale: CGFloat {
        switch self {
        case .small: Layout.Text.Factors.small
        case .medium: Layout.Text.Factors.medium
        case .large: Layout.Text.Factors.large
        case .extraLarge: Layout.Text.Factors.extraLarge
        }
    }

    /// `base` (the Medium size in points) scaled and rounded to a whole point.
    func points(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }

    func font(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: points(base), weight: weight)
    }
}

/// The three text sizes from Settings, shared by events and tasks (base sizes in Layout.Text):
/// - `heading`: EVENTS / TASKS, day headings and list names
/// - `name`: event and task titles
/// - `detail`: times, places, notes, due dates, and subtasks
struct TextSizes: Equatable {
    var heading = TextSize.medium
    var name = TextSize.medium
    var detail = TextSize.medium
}

private struct TextSizesKey: EnvironmentKey {
    static let defaultValue = TextSizes()
}

extension EnvironmentValues {
    var textSizes: TextSizes {
        get { self[TextSizesKey.self] }
        set { self[TextSizesKey.self] = newValue }
    }
}

/// Height of the menu bar panel, chosen in Settings → Styling (sizes in Layout.Popover.Height).
enum PanelHeight: String, CaseIterable, Identifiable {
    case short, standard, tall, extraTall

    var id: String { rawValue }
    var label: String {
        switch self {
        case .short: "Short"
        case .standard: "Standard"
        case .tall: "Tall"
        case .extraTall: "Extra tall"
        }
    }

    var points: CGFloat {
        switch self {
        case .short: Layout.Popover.Height.short
        case .standard: Layout.Popover.Height.standard
        case .tall: Layout.Popover.Height.tall
        case .extraTall: Layout.Popover.Height.extraTall
        }
    }

    /// `points`, but never taller than the space below the menu bar on the current screen.
    var fittedPoints: CGFloat {
        guard let available = NSScreen.main?.visibleFrame.height else { return points }
        return min(points, available - 20)
    }
}
