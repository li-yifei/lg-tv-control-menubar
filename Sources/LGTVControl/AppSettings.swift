import AppKit
import Foundation

enum ShortcutAction: String, CaseIterable {
    case volumeUp
    case volumeDown
    case toggleMute
    case powerOn
    case powerOff
    case pair
    case refresh
    case settings

    var title: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .toggleMute: return "Mute"
        case .powerOn: return "Power On"
        case .powerOff: return "Power Off"
        case .pair: return "Pair / Re-pair"
        case .refresh: return "Refresh"
        case .settings: return "Settings"
        }
    }

    var defaultKey: String {
        switch self {
        case .volumeUp: return "]"
        case .volumeDown: return "["
        case .toggleMute: return "m"
        case .powerOn: return "o"
        case .powerOff: return "f"
        case .pair: return "p"
        case .refresh: return "r"
        case .settings: return ","
        }
    }

    var defaultsKey: String {
        "shortcut.\(rawValue)"
    }

    var symbolName: String {
        switch self {
        case .volumeUp: return "speaker.plus.fill"
        case .volumeDown: return "speaker.minus.fill"
        case .toggleMute: return "speaker.slash.fill"
        case .powerOn: return "power.circle.fill"
        case .powerOff: return "power.circle"
        case .pair: return "link"
        case .refresh: return "arrow.clockwise"
        case .settings: return "gearshape"
        }
    }
}

final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("LGTVControlSettingsDidChange")

    private let defaults = UserDefaults.standard

    private init() {
        var registered: [String: Any] = [
            "safeVolumeReminderEnabled": true,
            "safeVolumeThreshold": 20,
        ]
        for action in ShortcutAction.allCases {
            registered[action.defaultsKey] = action.defaultKey
        }
        defaults.register(defaults: registered)
    }

    var safeVolumeReminderEnabled: Bool {
        get { defaults.bool(forKey: "safeVolumeReminderEnabled") }
        set {
            defaults.set(newValue, forKey: "safeVolumeReminderEnabled")
            notifyChanged()
        }
    }

    var safeVolumeThreshold: Int {
        get { defaults.integer(forKey: "safeVolumeThreshold") }
        set {
            defaults.set(max(0, min(100, newValue)), forKey: "safeVolumeThreshold")
            notifyChanged()
        }
    }

    func shortcut(for action: ShortcutAction) -> String {
        defaults.string(forKey: action.defaultsKey) ?? action.defaultKey
    }

    func setShortcut(_ shortcut: String, for action: ShortcutAction) {
        defaults.set(normalizeShortcut(shortcut), forKey: action.defaultsKey)
        notifyChanged()
    }

    func resetShortcuts() {
        for action in ShortcutAction.allCases {
            defaults.set(action.defaultKey, forKey: action.defaultsKey)
        }
        notifyChanged()
    }

    private func normalizeShortcut(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "space" {
            return " "
        }
        return trimmed.first.map { String($0).lowercased() } ?? ""
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
