import AppIntents
import Foundation

enum TVInputChoice: String, AppEnum {
    case hdmi1
    case hdmi2
    case hdmi3
    case hdmi4
    case lgChannels

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV Input")

    static let caseDisplayRepresentations: [TVInputChoice: DisplayRepresentation] = [
        .hdmi1: DisplayRepresentation(title: "HDMI 1"),
        .hdmi2: DisplayRepresentation(title: "HDMI 2"),
        .hdmi3: DisplayRepresentation(title: "HDMI 3"),
        .hdmi4: DisplayRepresentation(title: "HDMI 4"),
        .lgChannels: DisplayRepresentation(title: "LG Channels"),
    ]

    var inputId: String {
        switch self {
        case .hdmi1: return "HDMI_1"
        case .hdmi2: return "HDMI_2"
        case .hdmi3: return "HDMI_3"
        case .hdmi4: return "HDMI_4"
        case .lgChannels: return "MVPD_IP-com.webos.app.lgchannels"
        }
    }
}

struct TurnOnTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On TV"
    static let description = IntentDescription("Turns on the paired LG TV.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().powerOn()
        return .result(dialog: "Turning on the TV.")
    }
}

struct TurnOffTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off TV"
    static let description = IntentDescription("Turns off the paired LG TV.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().powerOff()
        return .result(dialog: "Turning off the TV.")
    }
}

struct VolumeUpTVIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Volume Up"
    static let description = IntentDescription("Raises the paired LG TV volume by one step.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().volumeUp()
        return .result(dialog: "Volume up.")
    }
}

struct VolumeDownTVIntent: AppIntent {
    static let title: LocalizedStringResource = "TV Volume Down"
    static let description = IntentDescription("Lowers the paired LG TV volume by one step.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().volumeDown()
        return .result(dialog: "Volume down.")
    }
}

struct SetTVVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set TV Volume"
    static let description = IntentDescription("Sets the paired LG TV volume from 0 to 100.")
    static let openAppWhenRun = false

    @Parameter(title: "Volume")
    var volume: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set TV volume to \(\.$volume)")
    }

    func perform() async throws -> some IntentResult {
        let clampedVolume = max(0, min(100, volume))
        try LGTVController().setVolume(clampedVolume)
        return .result(dialog: "Set TV volume to \(clampedVolume).")
    }
}

struct ToggleTVMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle TV Mute"
    static let description = IntentDescription("Toggles mute on the paired LG TV.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try LGTVController().toggleMute(currentMuted: nil)
        return .result(dialog: "Toggled mute.")
    }
}

struct SwitchTVInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch TV Input"
    static let description = IntentDescription("Switches the paired LG TV to an input.")
    static let openAppWhenRun = false

    @Parameter(title: "Input")
    var input: TVInputChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Switch TV input to \(\.$input)")
    }

    func perform() async throws -> some IntentResult {
        try LGTVController().switchInput(input.inputId)
        return .result(dialog: "Switched TV input.")
    }
}

struct LGTVControlShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnTVIntent(),
            phrases: [
                "Turn on \(.applicationName)",
                "Power on \(.applicationName)",
            ],
            shortTitle: "Turn On TV",
            systemImageName: "power.circle.fill"
        )
        AppShortcut(
            intent: TurnOffTVIntent(),
            phrases: [
                "Turn off \(.applicationName)",
                "Power off \(.applicationName)",
            ],
            shortTitle: "Turn Off TV",
            systemImageName: "power.circle"
        )
        AppShortcut(
            intent: SetTVVolumeIntent(),
            phrases: [
                "Set \(.applicationName) volume to \(\.$volume)",
                "Set TV volume in \(.applicationName) to \(\.$volume)",
            ],
            shortTitle: "Set Volume",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: VolumeUpTVIntent(),
            phrases: [
                "Turn up \(.applicationName)",
                "Increase \(.applicationName) volume",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.plus.fill"
        )
        AppShortcut(
            intent: VolumeDownTVIntent(),
            phrases: [
                "Turn down \(.applicationName)",
                "Decrease \(.applicationName) volume",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.minus.fill"
        )
        AppShortcut(
            intent: ToggleTVMuteIntent(),
            phrases: [
                "Mute \(.applicationName)",
                "Toggle mute in \(.applicationName)",
            ],
            shortTitle: "Mute",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: SwitchTVInputIntent(),
            phrases: [
                "Switch \(.applicationName) to \(\.$input)",
                "Change \(.applicationName) input to \(\.$input)",
            ],
            shortTitle: "Switch Input",
            systemImageName: "rectangle.connected.to.line.below"
        )
    }
}
