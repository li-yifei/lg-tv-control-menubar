import AppKit

let launchSettingsOnStart = CommandLine.arguments.dropFirst().contains("--show-settings")

if runCLIIfRequested() {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
