import AppKit
import Foundation

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settings = AppSettings.shared
    private let safeVolumeCheckbox = NSButton(checkboxWithTitle: "Safety volume reminder", target: nil, action: nil)
    private let thresholdField = NSTextField()
    private let thresholdStepper = NSStepper()
    private let cliStatusLabel = NSTextField(labelWithString: "")
    private let cliButton = NSButton(title: "", target: nil, action: nil)
    private var shortcutFields: [ShortcutAction: NSTextField] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.minSize = NSSize(width: 460, height: 580)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        loadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshCLIInstallState()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        root.addArrangedSubview(sectionLabel("Volume Safety"))

        safeVolumeCheckbox.target = self
        safeVolumeCheckbox.action = #selector(safeVolumeChanged)
        root.addArrangedSubview(safeVolumeCheckbox)

        let thresholdRow = NSStackView()
        thresholdRow.orientation = .horizontal
        thresholdRow.alignment = .centerY
        thresholdRow.spacing = 10
        thresholdRow.translatesAutoresizingMaskIntoConstraints = false
        thresholdRow.addArrangedSubview(rowLabel("Reminder threshold"))
        thresholdField.alignment = .right
        thresholdField.target = self
        thresholdField.action = #selector(thresholdChanged)
        thresholdField.delegate = self
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        thresholdRow.addArrangedSubview(thresholdField)
        thresholdStepper.minValue = 0
        thresholdStepper.maxValue = 100
        thresholdStepper.increment = 1
        thresholdStepper.target = self
        thresholdStepper.action = #selector(thresholdStepperChanged)
        thresholdRow.addArrangedSubview(thresholdStepper)
        root.addArrangedSubview(thresholdRow)

        root.addArrangedSubview(spacer(height: 10))
        root.addArrangedSubview(sectionLabel("Command Line Tool"))

        let cliRow = NSStackView()
        cliRow.orientation = .horizontal
        cliRow.alignment = .centerY
        cliRow.spacing = 12
        cliRow.translatesAutoresizingMaskIntoConstraints = false
        cliStatusLabel.lineBreakMode = .byTruncatingMiddle
        cliStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cliRow.addArrangedSubview(cliStatusLabel)

        let cliSpacer = NSView()
        cliSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cliRow.addArrangedSubview(cliSpacer)

        cliButton.target = self
        cliButton.action = #selector(toggleCLIInstall)
        cliButton.bezelStyle = .rounded
        cliRow.addArrangedSubview(cliButton)
        root.addArrangedSubview(cliRow)
        cliRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        root.addArrangedSubview(spacer(height: 10))
        root.addArrangedSubview(sectionLabel("Menu Shortcuts"))

        let shortcutsStack = NSStackView()
        shortcutsStack.orientation = .vertical
        shortcutsStack.alignment = .leading
        shortcutsStack.spacing = 8
        root.addArrangedSubview(shortcutsStack)

        for action in ShortcutAction.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.addArrangedSubview(rowLabel(action.title))

            let field = NSTextField()
            field.alignment = .center
            field.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            field.target = self
            field.action = #selector(shortcutChanged(_:))
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            shortcutFields[action] = field
            row.addArrangedSubview(field)

            shortcutsStack.addArrangedSubview(row)
        }

        let filler = NSView()
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(filler)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "Reset Shortcuts", target: self, action: #selector(resetShortcuts))
        buttonRow.addArrangedSubview(resetButton)

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(buttonSpacer)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(doneButton)
        root.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = label(text)
        field.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        return field
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let field = label(text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 170).isActive = true
        return field
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        return field
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func loadValues() {
        safeVolumeCheckbox.state = settings.safeVolumeReminderEnabled ? .on : .off
        thresholdField.integerValue = settings.safeVolumeThreshold
        thresholdStepper.integerValue = settings.safeVolumeThreshold

        for action in ShortcutAction.allCases {
            shortcutFields[action]?.stringValue = displayShortcut(settings.shortcut(for: action))
        }
        refreshCLIInstallState()
    }

    @objc private func safeVolumeChanged() {
        settings.safeVolumeReminderEnabled = safeVolumeCheckbox.state == .on
    }

    @objc private func thresholdChanged() {
        saveThreshold(thresholdField.integerValue)
    }

    @objc private func thresholdStepperChanged() {
        saveThreshold(thresholdStepper.integerValue)
    }

    @objc private func shortcutChanged(_ sender: NSTextField) {
        guard let rawValue = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: rawValue) else {
            return
        }
        settings.setShortcut(sender.stringValue, for: action)
        sender.stringValue = displayShortcut(settings.shortcut(for: action))
    }

    @objc private func resetShortcuts() {
        settings.resetShortcuts()
        loadValues()
    }

    @objc private func toggleCLIInstall() {
        do {
            if isCLIInstalled {
                try uninstallCLI()
            } else {
                try installCLI()
            }
            refreshCLIInstallState()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === thresholdField {
            saveThreshold(field.integerValue)
            return
        }

        guard let field = obj.object as? NSTextField,
              let rawValue = field.identifier?.rawValue,
              let action = ShortcutAction(rawValue: rawValue) else {
            return
        }
        settings.setShortcut(field.stringValue, for: action)
        field.stringValue = displayShortcut(settings.shortcut(for: action))
    }

    private func saveThreshold(_ value: Int) {
        settings.safeVolumeThreshold = value
        thresholdField.integerValue = settings.safeVolumeThreshold
        thresholdStepper.integerValue = settings.safeVolumeThreshold
    }

    private var cliInstallURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin/lgtv")
    }

    private var isCLIInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: cliInstallURL.path)
    }

    private func refreshCLIInstallState() {
        let displayPath = cliInstallURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if isCLIInstalled {
            cliStatusLabel.stringValue = "Installed at \(displayPath)"
            cliButton.title = "Uninstall CLI"
        } else {
            cliStatusLabel.stringValue = "Not installed. Target: \(displayPath)"
            cliButton.title = "Install CLI"
        }
    }

    private func installCLI() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw TVControlError.socket("Could not find the app executable.")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cliInstallURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: cliInstallURL.path) {
            try fileManager.removeItem(at: cliInstallURL)
        }
        try fileManager.copyItem(at: executableURL, to: cliInstallURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliInstallURL.path)
    }

    private func uninstallCLI() throws {
        if FileManager.default.fileExists(atPath: cliInstallURL.path) {
            try FileManager.default.removeItem(at: cliInstallURL)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Command Line Tool"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func displayShortcut(_ shortcut: String) -> String {
        shortcut == " " ? "space" : shortcut
    }
}
