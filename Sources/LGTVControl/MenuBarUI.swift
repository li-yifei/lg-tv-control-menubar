import AppKit
import Foundation

final class SafetyVolumePromptView: NSView {
    private let onContinue: () -> Void
    private let onCancel: () -> Void

    init(targetVolume: Int, threshold: Int, onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onContinue = onContinue
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 104))
        build(targetVolume: targetVolume, threshold: threshold)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(targetVolume: Int, threshold: Int) {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = NSColor.systemYellow.withAlphaComponent(0.7)
        box.fillColor = NSColor.systemYellow.withAlphaComponent(0.14)
        box.cornerRadius = 8
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)

        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            ])
        }

        let title = NSTextField(labelWithString: "Volume safety")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(title)

        let message = NSTextField(labelWithString: "Set volume to \(targetVolume)? Threshold is \(threshold).")
        message.font = NSFont.menuFont(ofSize: 0)
        message.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(message)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        buttons.addArrangedSubview(cancelButton)

        let continueButton = NSButton(title: "Continue", target: self, action: #selector(continueAction))
        continueButton.bezelStyle = .rounded
        continueButton.bezelColor = .systemYellow
        continueButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(continueButton)

        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func cancel() {
        onCancel()
    }

    @objc private func continueAction() {
        onContinue()
    }
}

final class SafetyVolumeSlider: NSSlider {
    var isTrackingMouse = false
    var onTrackingEnded: (() -> Void)?

    var safetyThreshold: Int = 20 {
        didSet {
            needsDisplay = true
        }
    }

    var safetyEnabled: Bool = true {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawThresholdMark()
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        onTrackingEnded?()
    }

    private func drawThresholdMark() {
        guard safetyEnabled,
              maxValue > minValue,
              safetyThreshold > Int(minValue),
              safetyThreshold < Int(maxValue) else {
            return
        }

        let usableWidth = bounds.width - 12
        let ratio = CGFloat((Double(safetyThreshold) - minValue) / (maxValue - minValue))
        let x = bounds.minX + 6 + usableWidth * ratio
        let markRect = NSRect(x: x - 1, y: bounds.midY - 7, width: 2, height: 14)
        NSColor.systemYellow.setFill()
        NSBezierPath(roundedRect: markRect, xRadius: 1, yRadius: 1).fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let controller = LGTVController()
    private let settings = AppSettings.shared
    private var currentState: TVState?
    private var currentInputs: [TVInput] = []
    private var isBusy = false
    private var settingsWindowController: SettingsWindowController?
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    private var menuKeyMonitor: Any?
    private var volumeMenuItem: NSMenuItem?
    private var safetyVolumePromptItem: NSMenuItem?
    private var safetyVolumeCancelHandler: (() -> Void)?
    private var safetyVolumeDidConfirm = false
    private var volumeControlsView: NSView?
    private let inputMenu = NSMenu()

    private let titleItem = NSMenuItem(title: "LG TV Control", action: nil, keyEquivalent: "")
    private let titleLabel = NSTextField(labelWithString: "LG TV Control")
    private let statusLineItem = NSMenuItem(title: "Volume: --", action: nil, keyEquivalent: "")
    private let slider = SafetyVolumeSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: #selector(sliderChanged(_:)))
    private let sliderLabel = NSTextField(labelWithString: "--")
    private let volumeDownButton = NSButton(frame: .zero)
    private let volumeUpButton = NSButton(frame: .zero)
    private let muteButton = NSButton(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "tv.fill", accessibilityDescription: "LG TV Control") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "LG"
            }
        }

        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: AppSettings.didChangeNotification,
            object: nil
        )
        refreshStatus()
        if launchSettingsOnStart {
            DispatchQueue.main.async {
                self.openSettings()
            }
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        inputMenu.autoenablesItems = false
        titleItem.isEnabled = true
        titleItem.view = titleHeaderView()
        menu.addItem(titleItem)

        statusLineItem.isEnabled = false

        menu.addItem(NSMenuItem.separator())
        menu.addItem(sliderItem())
        menu.addItem(NSMenuItem.separator())

        menu.addItem(shortcutMenuItem(title: "Power On", action: #selector(powerOn), shortcutAction: .powerOn))
        menu.addItem(shortcutMenuItem(title: "Power Off", action: #selector(powerOff), shortcutAction: .powerOff))

        menu.addItem(NSMenuItem.separator())
        let inputItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        inputItem.image = menuIcon("rectangle.connected.to.line.below")
        inputItem.submenu = inputMenu
        inputItem.isEnabled = true
        menu.addItem(inputItem)
        rebuildInputMenu()

        menu.addItem(NSMenuItem.separator())

        let extraMenu = NSMenu()
        extraMenu.autoenablesItems = false
        let extraItem = NSMenuItem(title: "Extra", action: nil, keyEquivalent: "")
        extraItem.image = menuIcon("wrench.and.screwdriver")
        extraItem.submenu = extraMenu
        extraItem.isEnabled = true
        menu.addItem(extraItem)

        let inStartItem = NSMenuItem(title: "InStart Menu", action: #selector(openInStartMenu), keyEquivalent: "")
        inStartItem.target = self
        inStartItem.image = menuIcon("gearshape.2")
        inStartItem.isEnabled = true
        extraMenu.addItem(inStartItem)

        let ezAdjustItem = NSMenuItem(title: "EZ Adjust", action: #selector(openEZAdjust), keyEquivalent: "")
        ezAdjustItem.target = self
        ezAdjustItem.image = menuIcon("slider.horizontal.3")
        ezAdjustItem.isEnabled = true
        extraMenu.addItem(ezAdjustItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(shortcutMenuItem(title: "Pair / Re-pair", action: #selector(pairTV), shortcutAction: .pair))
        menu.addItem(shortcutMenuItem(title: "Settings...", action: #selector(openSettings), shortcutAction: .settings))
        menu.addItem(shortcutMenuItem(title: "Refresh", action: #selector(refreshStatusAction), shortcutAction: .refresh))
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.image = menuIcon("xmark.circle")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        for item in menu.items where item.action != nil {
            item.target = self
        }
        updateMenuShortcuts()
    }

    private func shortcutMenuItem(title: String, action: Selector, shortcutAction: ShortcutAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = menuIcon(shortcutAction.symbolName)
        item.isEnabled = true
        shortcutItems[shortcutAction] = item
        return item
    }

    private func titleHeaderView() -> NSView {
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 34))
        titleLabel.frame = NSRect(x: 28, y: 8, width: 318, height: 18)
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        wrapper.addSubview(titleLabel)
        return wrapper
    }

    private func menuIcon(_ symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func rebuildInputMenu() {
        inputMenu.removeAllItems()

        if currentInputs.isEmpty {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            inputMenu.addItem(item)
            return
        }

        for input in currentInputs {
            let item = NSMenuItem(title: inputTitle(input), action: #selector(selectInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = input.id
            item.image = menuIcon(input.hasSignal ? "cable.connector.horizontal" : "cable.connector")
            item.isEnabled = true
            if let currentAppId = currentState?.currentAppId,
               input.appId == currentAppId {
                item.state = .on
            }
            inputMenu.addItem(item)
        }
    }

    private func inputTitle(_ input: TVInput) -> String {
        let normalizedId = input.id.replacingOccurrences(of: "_", with: " ")
        if input.label.caseInsensitiveCompare(normalizedId) == .orderedSame || input.label == input.id {
            return normalizedId
        }
        return "\(input.label) (\(normalizedId))"
    }

    private func sliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true
        volumeMenuItem = item
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 38))
        volumeControlsView = wrapper

        configureVolumeButton(volumeDownButton, symbolName: "speaker.minus.fill", action: #selector(volumeDown), tooltip: "Volume Down")
        configureVolumeButton(volumeUpButton, symbolName: "speaker.plus.fill", action: #selector(volumeUp), tooltip: "Volume Up")
        configureVolumeButton(muteButton, symbolName: ShortcutAction.toggleMute.symbolName, action: #selector(toggleMute), tooltip: "Mute")
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.isEnabled = true
        slider.cell?.isEnabled = true
        slider.safetyThreshold = settings.safeVolumeThreshold
        slider.safetyEnabled = settings.safeVolumeReminderEnabled
        slider.target = self
        slider.onTrackingEnded = { [weak self] in
            self?.commitSliderValue()
        }
        sliderLabel.alignment = .right

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)

        row.addArrangedSubview(volumeDownButton)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(volumeUpButton)
        row.addArrangedSubview(muteButton)
        row.addArrangedSubview(sliderLabel)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 28),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -28),
            row.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            volumeDownButton.widthAnchor.constraint(equalToConstant: 28),
            volumeDownButton.heightAnchor.constraint(equalToConstant: 28),
            volumeUpButton.widthAnchor.constraint(equalToConstant: 28),
            volumeUpButton.heightAnchor.constraint(equalToConstant: 28),
            muteButton.widthAnchor.constraint(equalToConstant: 28),
            muteButton.heightAnchor.constraint(equalToConstant: 28),
            sliderLabel.widthAnchor.constraint(equalToConstant: 26),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        item.view = wrapper
        return item
    }

    private func configureVolumeButton(_ button: NSButton, symbolName: String, action: Selector, tooltip: String) {
        button.target = self
        button.action = action
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = menuIcon(symbolName)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.isEnabled = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.toolTip = tooltip
    }

    func menuWillOpen(_ menu: NSMenu) {
        installMenuKeyMonitor()
        refreshStatus()
    }

    func menuDidClose(_ menu: NSMenu) {
        removeMenuKeyMonitor()
        removeSafetyVolumePrompt(shouldCancel: true)
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let inputId = sender.representedObject as? String else { return }
        runCommand(statusText: "Switching input...") { try self.controller.switchInput(inputId) }
    }

    @objc private func volumeUp() {
        if let volume = currentState?.volume {
            let targetVolume = min(100, volume + 1)
            if requiresSafeVolumeConfirmation(targetVolume: targetVolume) {
                showSafeVolumeConfirmation(targetVolume: targetVolume) {
                    self.runCommand(statusText: "Volume up...") { try self.controller.volumeUp() }
                }
                return
            }
        }
        runCommand(statusText: "Volume up...") { try self.controller.volumeUp() }
    }

    @objc private func volumeDown() {
        runCommand(statusText: "Volume down...") { try self.controller.volumeDown() }
    }

    @objc private func toggleMute() {
        runCommand(statusText: "Toggling mute...") { try self.controller.toggleMute(currentMuted: self.currentState?.muted) }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = Int(sender.integerValue)
        updateSliderLabel(value)
        guard (sender as? SafetyVolumeSlider)?.isTrackingMouse != true else {
            return
        }
        commitSliderValue()
    }

    private func commitSliderValue() {
        let rollbackVolume = currentState?.volume
        let value = Int(slider.integerValue)
        updateSliderLabel(value)
        guard value != rollbackVolume else {
            return
        }
        if requiresSafeVolumeConfirmation(targetVolume: value) {
            showSafeVolumeConfirmation(
                targetVolume: value,
                onContinue: {
                    self.runCommand(statusText: "Setting volume \(value)...") { try self.controller.setVolume(value) }
                },
                onCancel: {
                    self.restoreSliderVolume(to: rollbackVolume)
                }
            )
            return
        }
        runCommand(statusText: "Setting volume \(value)...") { try self.controller.setVolume(value) }
    }

    @objc private func powerOn() {
        runCommand(statusText: "Powering on...") { try self.controller.powerOn() }
    }

    @objc private func powerOff() {
        runCommand(statusText: "Powering off...") { try self.controller.powerOff() }
    }

    @objc private func pairTV() {
        let defaultHost = controller.configuredHost() ?? ""
        guard let host = promptForHost(defaultValue: defaultHost) else { return }
        runCommand(statusText: "Pairing...") { try self.controller.pair(host: host, forcePairing: true) }
    }

    @objc private func refreshStatusAction() {
        refreshStatus()
    }

    @objc private func openInStartMenu() {
        runCommand(statusText: "Opening InStart...") { try self.controller.launchFactoryApp(irKey: "inStart", pin: "0413") }
    }

    @objc private func openEZAdjust() {
        runCommand(statusText: "Opening EZ Adjust...") { try self.controller.launchFactoryApp(irKey: "ezAdjust", pin: "0413") }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(controller: controller)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsChanged() {
        slider.safetyThreshold = settings.safeVolumeThreshold
        slider.safetyEnabled = settings.safeVolumeReminderEnabled
        updateSliderLabel(Int(slider.integerValue))
        updateMenuShortcuts()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshStatus() {
        runCommand(statusText: "Refreshing...") {
            self.currentState = try self.controller.status()
            self.currentInputs = (try? self.controller.inputList()) ?? self.currentInputs
        }
    }

    private func runCommand(statusText: String, work: @escaping () throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        updateStatus(statusText)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
                if !["Refreshing...", "Powering off...", "Powering on..."].contains(statusText) {
                    self.currentState = try self.controller.status()
                    self.currentInputs = (try? self.controller.inputList()) ?? self.currentInputs
                }
                DispatchQueue.main.async {
                    self.applyState()
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateStatus(error.localizedDescription)
                    self.isBusy = false
                }
            }
        }
    }

    private func applyState() {
        guard let state = currentState else {
            updateStatus("Volume: --")
            return
        }

        let volumeText = state.volume.map(String.init) ?? "--"
        let mutedText = state.muted == true ? " muted" : ""
        let modelText = state.model.map { " \($0)" } ?? ""
        statusLineItem.title = "Volume: \(volumeText)\(mutedText)"
        titleLabel.stringValue = "LG TV\(modelText)"
        muteButton.image = menuIcon(state.muted == true ? "speaker.wave.2.fill" : ShortcutAction.toggleMute.symbolName)
        rebuildInputMenu()

        if let volume = state.volume {
            slider.integerValue = volume
            updateSliderLabel(volume)
        } else {
            sliderLabel.stringValue = "--"
            sliderLabel.textColor = .labelColor
        }

        statusItem.button?.toolTip = "LG TV Volume \(volumeText)\(mutedText)"
        updateVolumeButtonTooltips()
    }

    private func updateStatus(_ text: String) {
        statusLineItem.title = text
        statusItem.button?.toolTip = text
    }

    private func updateMenuShortcuts() {
        for (action, item) in shortcutItems {
            let shortcut = settings.shortcut(for: action)
            item.keyEquivalent = shortcut
            item.keyEquivalentModifierMask = []
        }
        updateVolumeButtonTooltips()
    }

    private func updateVolumeButtonTooltips() {
        volumeDownButton.toolTip = tooltip(for: .volumeDown)
        volumeUpButton.toolTip = tooltip(for: .volumeUp)
        let muteTitle = currentState?.muted == true ? "Unmute" : "Mute"
        muteButton.toolTip = tooltip(title: muteTitle, shortcut: settings.shortcut(for: .toggleMute))
    }

    private func updateSliderLabel(_ value: Int) {
        sliderLabel.stringValue = String(value)
        if requiresSafeVolumeConfirmation(targetVolume: value) {
            sliderLabel.textColor = .systemYellow
        } else {
            sliderLabel.textColor = .labelColor
        }
    }

    private func tooltip(for action: ShortcutAction) -> String {
        tooltip(title: action.title, shortcut: settings.shortcut(for: action))
    }

    private func tooltip(title: String, shortcut: String) -> String {
        let display = displayShortcut(shortcut)
        return display.isEmpty ? title : "\(title) (\(display))"
    }

    private func installMenuKeyMonitor() {
        guard menuKeyMonitor == nil else { return }
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.volumeShortcutAction(for: event) else {
                return event
            }
            self.runVolumeShortcut(action)
            return nil
        }
    }

    private func removeMenuKeyMonitor() {
        guard let menuKeyMonitor else { return }
        NSEvent.removeMonitor(menuKeyMonitor)
        self.menuKeyMonitor = nil
    }

    private func volumeShortcutAction(for event: NSEvent) -> ShortcutAction? {
        let modifiersToIgnore: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(modifiersToIgnore).isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }

        for action in [ShortcutAction.volumeUp, .volumeDown, .toggleMute] {
            if characters == settings.shortcut(for: action) {
                return action
            }
        }
        return nil
    }

    private func runVolumeShortcut(_ action: ShortcutAction) {
        switch action {
        case .volumeUp:
            volumeUp()
        case .volumeDown:
            volumeDown()
        case .toggleMute:
            toggleMute()
        default:
            break
        }
    }

    private func displayShortcut(_ shortcut: String) -> String {
        if shortcut == " " {
            return "Space"
        }
        return shortcut.count == 1 ? shortcut.uppercased() : shortcut
    }

    private func requiresSafeVolumeConfirmation(targetVolume: Int) -> Bool {
        settings.safeVolumeReminderEnabled && targetVolume > settings.safeVolumeThreshold
    }

    private func showSafeVolumeConfirmation(
        targetVolume: Int,
        onContinue: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        removeSafetyVolumePrompt(shouldCancel: false)

        safetyVolumeDidConfirm = false
        safetyVolumeCancelHandler = onCancel

        let promptItem = NSMenuItem()
        promptItem.isEnabled = true
        promptItem.view = SafetyVolumePromptView(
            targetVolume: targetVolume,
            threshold: settings.safeVolumeThreshold,
            onContinue: { [weak self] in
                self?.safetyVolumeDidConfirm = true
                self?.safetyVolumeCancelHandler = nil
                self?.removeSafetyVolumePrompt(shouldCancel: false)
                onContinue()
            },
            onCancel: { [weak self] in
                self?.removeSafetyVolumePrompt(shouldCancel: true)
            }
        )
        safetyVolumePromptItem = promptItem

        let insertIndex: Int
        if let volumeMenuItem,
           let volumeIndex = menu.items.firstIndex(of: volumeMenuItem) {
            insertIndex = volumeIndex + 1
        } else {
            insertIndex = min(2, menu.items.count)
        }
        menu.insertItem(promptItem, at: insertIndex)
    }

    private func removeSafetyVolumePrompt(shouldCancel: Bool) {
        if let safetyVolumePromptItem {
            menu.removeItem(safetyVolumePromptItem)
            self.safetyVolumePromptItem = nil
        }
        if shouldCancel, !safetyVolumeDidConfirm {
            let cancelHandler = safetyVolumeCancelHandler
            safetyVolumeCancelHandler = nil
            cancelHandler?()
        } else {
            safetyVolumeCancelHandler = nil
        }
        safetyVolumeDidConfirm = false
    }

    private func restoreSliderVolume(to rollbackVolume: Int?) {
        if let volume = rollbackVolume ?? currentState?.volume {
            slider.integerValue = volume
            updateSliderLabel(volume)
        }
    }

    private func promptForHost(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Pair LG TV"
        alert.informativeText = "Accept the pairing prompt on the TV after starting."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "TV IP address"
        field.stringValue = defaultValue
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
    }
}
