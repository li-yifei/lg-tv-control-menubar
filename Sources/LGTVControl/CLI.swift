import ArgumentParser
import Foundation

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

struct CommonOptions: ParsableArguments {
    @Option(name: .customLong("config"), help: "Pairing JSON path. Defaults to LG_TV_CONFIG, then ~/.config/lgtv-pairing.json.")
    var configPath: String?

    func controller() -> LGTVController {
        LGTVController(configPath: configPath)
    }
}

struct OutputOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Output format: text or json.")
    var format: OutputFormat = .text

    @Flag(name: .customLong("json"), help: "Shortcut for --format json.")
    var json = false

    var resolvedFormat: OutputFormat {
        json ? .json : format
    }
}

struct QuietOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Suppress the final ok line.")
    var quiet = false
}

struct LGTVCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lgtv",
        abstract: "Control a paired LG webOS TV from the terminal.",
        discussion: """
        Reads pairing credentials from Keychain and config from ~/.config/lgtv-pairing.json by default.
        Override the config path with --config PATH on a command, or set LG_TV_CONFIG.

        Examples:
          lgtv status
          lgtv status --json
          lgtv volume set 12
          lgtv volume up --steps 3
          lgtv mute on
          lgtv input list
          lgtv input switch HDMI_2
          lgtv power on
          lgtv raw ssap://audio/getVolume --json
        """,
        version: "0.3.0",
        subcommands: [
            StatusCommand.self,
            InputsCommand.self,
            PairCommand.self,
            VolumeCommand.self,
            MuteCommand.self,
            PowerCommand.self,
            InputCommand.self,
            RawCommand.self,
            ConfigCommand.self,
            AppCommand.self,
        ]
    )
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print TV host, model, volume, mute state, and current foreground app."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON(stateJSONObject(state))
        case .text:
            writeLine("Host: \(state.host)")
            writeLine("Model: \(state.model ?? "-")")
            writeLine("Volume: \(state.volume.map(String.init) ?? "-")")
            writeLine("Muted: \(state.muted.map(boolText) ?? "-")")
            writeLine("Current App: \(state.currentAppId ?? "-")")
        }
    }
}

struct InputsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inputs",
        abstract: "List TV input sources.",
        discussion: "Alias-style top-level command for `lgtv input list`."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try printInputs(controller: common.controller(), format: output.resolvedFormat)
    }
}

struct PairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair or re-pair the TV and save the client key.",
        discussion: "When HOST is omitted, the saved host from the config file is used. Accept the prompt shown on the TV."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Argument(help: "TV host or IP address. Uses the saved host when omitted.")
    var host: String?

    @Flag(name: .customLong("reuse-key"), help: "Try the saved client key before showing a TV pairing prompt.")
    var reuseKey = false

    func run() throws {
        let controller = common.controller()
        let resolvedHost = host ?? controller.configuredHost()
        guard let resolvedHost, !resolvedHost.isEmpty else {
            throw ValidationError("Missing host. Use `lgtv pair <host>`.")
        }
        try controller.pair(host: resolvedHost, forcePairing: !reuseKey)
        writeOK("paired \(resolvedHost)", quiet: quiet.quiet)
    }
}

struct VolumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Read or change TV volume.",
        subcommands: [
            VolumeGetCommand.self,
            VolumeSetCommand.self,
            VolumeUpCommand.self,
            VolumeDownCommand.self,
        ]
    )
}

struct VolumeGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print current TV volume.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON([
                "volume": nullable(state.volume),
                "muted": nullable(state.muted),
            ])
        case .text:
            writeLine(state.volume.map(String.init) ?? "-")
        }
    }
}

struct VolumeSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set TV volume to an exact value from 0 to 100.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Argument(help: "Volume value from 0 to 100.")
    var value: Int

    func validate() throws {
        guard (0...100).contains(value) else {
            throw ValidationError("Volume must be between 0 and 100.")
        }
    }

    func run() throws {
        try common.controller().setVolume(value)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct VolumeUpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Raise TV volume by one or more steps.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Option(name: .shortAndLong, help: "Number of one-step volume increments.")
    var steps = 1

    func validate() throws {
        guard steps >= 1 else {
            throw ValidationError("Steps must be at least 1.")
        }
    }

    func run() throws {
        let controller = common.controller()
        for _ in 0..<steps {
            try controller.volumeUp()
        }
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct VolumeDownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "Lower TV volume by one or more steps.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Option(name: .shortAndLong, help: "Number of one-step volume decrements.")
    var steps = 1

    func validate() throws {
        guard steps >= 1 else {
            throw ValidationError("Steps must be at least 1.")
        }
    }

    func run() throws {
        let controller = common.controller()
        for _ in 0..<steps {
            try controller.volumeDown()
        }
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct MuteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute",
        abstract: "Read or change mute state.",
        subcommands: [
            MuteStatusCommand.self,
            MuteToggleCommand.self,
            MuteOnCommand.self,
            MuteOffCommand.self,
        ]
    )
}

struct MuteStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Print current mute state.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON(["muted": nullable(state.muted)])
        case .text:
            writeLine(state.muted.map(boolText) ?? "-")
        }
    }
}

struct MuteToggleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "toggle", abstract: "Toggle mute.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().toggleMute(currentMuted: nil)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct MuteOnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "on", abstract: "Mute the TV.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().setMute(true)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct MuteOffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Unmute the TV.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().setMute(false)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct PowerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "power",
        abstract: "Turn the TV on or off.",
        subcommands: [
            PowerOnCommand.self,
            PowerOffCommand.self,
        ]
    )
}

struct PowerOnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "on", abstract: "Wake the TV using Wake-on-LAN.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().powerOn()
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct PowerOffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Turn the TV off through the webOS API.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try common.controller().powerOff()
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct InputCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "List, inspect, or switch TV input sources.",
        subcommands: [
            InputListCommand.self,
            InputCurrentCommand.self,
            InputSwitchCommand.self,
        ]
    )
}

struct InputListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List TV input sources.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try printInputs(controller: common.controller(), format: output.resolvedFormat)
    }
}

struct InputCurrentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "current", abstract: "Print current foreground app ID.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let state = try common.controller().status()
        switch output.resolvedFormat {
        case .json:
            try writeJSON(["currentAppId": nullable(state.currentAppId)])
        case .text:
            writeLine(state.currentAppId ?? "-")
        }
    }
}

struct InputSwitchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "switch", abstract: "Switch to an input ID from `lgtv input list`.")

    @OptionGroup var common: CommonOptions
    @OptionGroup var quiet: QuietOptions

    @Argument(help: "Input ID, for example HDMI_2 or MVPD_IP-com.webos.app.lgchannels.")
    var inputId: String

    func run() throws {
        try common.controller().switchInput(inputId)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct RawCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raw",
        abstract: "Send a raw webOS SSAP request.",
        discussion: "Payload must be a JSON object. The response payload is printed as JSON."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "SSAP URI, for example ssap://audio/getVolume.")
    var uri: String

    @Option(name: .shortAndLong, help: "JSON object payload, for example '{\"volume\":12}'.")
    var payload: String?

    @Flag(name: .customLong("json"), help: "Accepted for consistency. Raw responses are always JSON.")
    var json = false

    func run() throws {
        let requestPayload = try payload.map(parseJSONObject)
        let response = try common.controller().rawRequest(uri: uri, payload: requestPayload)
        try writeJSON(response)
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect local CLI configuration.",
        subcommands: [
            ConfigPathCommand.self,
        ]
    )
}

struct ConfigPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the pairing config path used by this command.")

    @OptionGroup var common: CommonOptions

    func run() throws {
        writeLine(common.controller().configPath)
    }
}

struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Open the menu bar app from the CLI.",
        subcommands: [
            AppOpenCommand.self,
            AppSettingsCommand.self,
        ]
    )
}

struct AppOpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open the menu bar app.")

    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try openInstalledApp(showSettings: false)
        writeOK("ok", quiet: quiet.quiet)
    }
}

struct AppSettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "settings", abstract: "Open the app settings window.")

    @OptionGroup var quiet: QuietOptions

    func run() throws {
        try openInstalledApp(showSettings: true)
        writeOK("ok", quiet: quiet.quiet)
    }
}

func stateJSONObject(_ state: TVState) -> [String: Any] {
    [
        "host": state.host,
        "model": state.model ?? NSNull(),
        "volume": state.volume ?? NSNull(),
        "muted": state.muted ?? NSNull(),
        "currentAppId": state.currentAppId ?? NSNull(),
    ]
}

func inputJSONObject(_ input: TVInput) -> [String: Any] {
    [
        "id": input.id,
        "label": input.label,
        "appId": input.appId ?? NSNull(),
        "connected": input.connected,
        "hasSignal": input.hasSignal,
    ]
}

func printInputs(controller: LGTVController, format: OutputFormat) throws {
    let inputs = try controller.inputList()
    switch format {
    case .json:
        try writeJSON(inputs.map(inputJSONObject))
    case .text:
        writeLine("ID\tLABEL\tAPP_ID\tCONNECTED\tSIGNAL")
        for input in inputs {
            writeLine("\(input.id)\t\(input.label)\t\(input.appId ?? "-")\t\(boolText(input.connected))\t\(boolText(input.hasSignal))")
        }
    }
}

func nullable<T>(_ value: T?) -> Any {
    value ?? NSNull()
}

func parseJSONObject(_ raw: String) throws -> [String: Any] {
    guard let data = raw.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ValidationError("Payload must be a JSON object.")
    }
    return object
}

func writeJSON(_ object: Any) throws {
    guard JSONSerialization.isValidJSONObject(object) else {
        throw TVControlError.invalidJSON
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func writeLine(_ text: String) {
    FileHandle.standardOutput.write(Data("\(text)\n".utf8))
}

func writeOK(_ text: String, quiet: Bool) {
    guard !quiet else { return }
    writeLine(text)
}

func boolText(_ value: Bool) -> String {
    value ? "true" : "false"
}

func openInstalledApp(showSettings: Bool) throws {
    let bundlePath = Bundle.main.bundlePath
    let appPath = bundlePath.hasSuffix(".app")
        ? bundlePath
        : NSHomeDirectory() + "/Applications/LG TV Control.app"
    var arguments = [appPath]
    if showSettings {
        arguments.append(contentsOf: ["--args", "--show-settings"])
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TVControlError.socket("Failed to open app at \(appPath).")
    }
}

func runCLIIfRequested() -> Bool {
    let args = normalizeLeadingGlobalOptions(Array(CommandLine.arguments.dropFirst()))
    let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    let invokedAsCLI = executableName == "lgtv"
    guard let normalizedArgs = normalizedCLIArguments(args, invokedAsCLI: invokedAsCLI) else {
        return false
    }
    LGTVCLI.main(normalizedArgs)
    return true
}

func normalizedCLIArguments(_ args: [String], invokedAsCLI: Bool) -> [String]? {
    guard let first = args.first else {
        return invokedAsCLI ? ["--help"] : nil
    }

    if first == "--show-settings" {
        return nil
    }

    if first == "--cli" {
        let rest = Array(args.dropFirst())
        return rest.isEmpty ? ["--help"] : rest
    }

    switch first {
    case "--status":
        return ["status", "--format", "json"] + Array(args.dropFirst())
    case "--inputs":
        return ["inputs", "--format", "json"] + Array(args.dropFirst())
    case "--pair":
        return ["pair"] + Array(args.dropFirst())
    case "--set-volume":
        return ["volume", "set"] + Array(args.dropFirst())
    case "--volume-up":
        return ["volume", "up"] + Array(args.dropFirst())
    case "--volume-down":
        return ["volume", "down"] + Array(args.dropFirst())
    case "--toggle-mute":
        return ["mute", "toggle"] + Array(args.dropFirst())
    case "--power-on":
        return ["power", "on"] + Array(args.dropFirst())
    case "--power-off":
        return ["power", "off"] + Array(args.dropFirst())
    case "--set-input":
        return ["input", "switch"] + Array(args.dropFirst())
    case "--help", "-h", "--version", "help":
        return args
    default:
        let commandNames: Set<String> = [
            "status",
            "inputs",
            "pair",
            "volume",
            "mute",
            "power",
            "input",
            "raw",
            "config",
            "app",
        ]
        if commandNames.contains(first) || invokedAsCLI {
            return args
        }
        return nil
    }
}

func normalizeLeadingGlobalOptions(_ args: [String]) -> [String] {
    var index = 0
    var globalOptions: [String] = []

    while index < args.count {
        let argument = args[index]
        if argument == "--config" {
            globalOptions.append(argument)
            if index + 1 < args.count {
                globalOptions.append(args[index + 1])
                index += 2
            } else {
                index += 1
            }
            continue
        }
        if argument.hasPrefix("--config=") {
            globalOptions.append("--config")
            globalOptions.append(String(argument.dropFirst("--config=".count)))
            index += 1
            continue
        }
        break
    }

    guard !globalOptions.isEmpty else {
        return args
    }

    var rest = Array(args.dropFirst(index))
    guard !rest.isEmpty else {
        return globalOptions
    }

    let insertionIndex = commonOptionInsertionIndex(rest)
    rest.insert(contentsOf: globalOptions, at: insertionIndex)
    return rest
}

func commonOptionInsertionIndex(_ args: [String]) -> Int {
    guard let first = args.first else {
        return 0
    }

    let oneLevelCommands: Set<String> = [
        "status",
        "inputs",
        "pair",
        "raw",
        "--status",
        "--inputs",
        "--pair",
        "--set-volume",
        "--volume-up",
        "--volume-down",
        "--toggle-mute",
        "--power-on",
        "--power-off",
        "--set-input",
    ]
    if oneLevelCommands.contains(first) {
        return min(1, args.count)
    }

    let twoLevelCommands: Set<String> = [
        "volume",
        "mute",
        "power",
        "input",
        "config",
    ]
    if twoLevelCommands.contains(first) {
        return min(2, args.count)
    }

    return 0
}
