import Cocoa

final class ProductState: NSObject {
    weak var toolsButton: NSPopUpButton?
    let characterLabel = NSTextField(labelWithString: "0 / 8,000")
    let activity = NSProgressIndicator()
    var keyMonitor: Any?
    var screenObserver: NSObjectProtocol?
    var wakeObserver: NSObjectProtocol?
    var lastPrompt = ""
    var lastResponse = ""
    var clearedConversation: NSAttributedString?
    var reconnectAttempt = 0
    var reconnectWorkItem: DispatchWorkItem?
    var screenPermissionWarningShown = false
    var lastRuntimeLog = ""
    var lastRuntimeLogDate = Date.distantPast
    var runtimeLogRepeat = 0
    var streamTextStart: Int?
    var resizeStart = (mouse: NSPoint.zero, frame: NSRect.zero)
    var resizeGrip: NSView?
    var lastLevelUpdate = Date.distantPast
    var textSize = max(11, min(20, UserDefaults.standard.double(forKey: "product.textSize") == 0 ? 13 : UserDefaults.standard.double(forKey: "product.textSize")))
    var timestamps = UserDefaults.standard.bool(forKey: "product.timestamps")
    var highContrast = UserDefaults.standard.bool(forKey: "product.highContrast")
    var solidBackground = UserDefaults.standard.bool(forKey: "product.solidBackground")
    var pinned = UserDefaults.standard.object(forKey: "product.pinned") as? Bool ?? true
    var appearance = UserDefaults.standard.string(forKey: "product.appearance") ?? "system"
    var opacity = UserDefaults.standard.object(forKey: "product.opacity") as? Double ?? 1
}

extension AppDelegate {
    func installProductUpgrades(to toolsButton: NSPopUpButton) {
        precondition(UpgradeCatalog.items.count == 100, "Kodros Orb must ship exactly 100 cataloged upgrades")
        product.toolsButton = toolsButton
        configureUpgradeViews()
        buildUpgradeMenus(in: toolsButton.menu)
        installUpgradeKeyboardRouter()
        installDisplayObservers()
        installResizeSupport()
        restoreComposerDraft()
        applyProductAppearance()
        applyPinnedState()
    }

    // MARK: - Panel resizing

    // Every expanded view gets autoresizing masks so the frame math in
    // handleResizeDrag is the only layout work needed. The grip lives in
    // the bottom bar, so it hides with the panel chrome automatically.
    func installResizeSupport() {
        materialView.autoresizingMask = [.width, .height]
        topBar.autoresizingMask = [.width, .minYMargin]
        for btn in [product.toolsButton as NSButton?, lookBtn, voiceBtn].compactMap({ $0 }) {
            btn.autoresizingMask = [.minXMargin]
        }
        outputScroll.autoresizingMask = [.width, .height]
        welcomeView.autoresizingMask = [.width, .height]
        for sub in welcomeView.subviews { sub.autoresizingMask = [.minXMargin, .maxXMargin] }
        inputBar.autoresizingMask = [.width, .maxYMargin]
        inputField.autoresizingMask = [.width, .maxYMargin]
        sendBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        modelLabel.autoresizingMask = [.minXMargin, .maxYMargin]
        modelLabel.frame = NSRect(x: panelW - 220, y: 6, width: 164, height: 16)
        product.characterLabel.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        product.activity.autoresizingMask = [.minXMargin]

        let grip = ResizeGripView(frame: NSRect(x: panelW - 28, y: 0, width: 28, height: 28))
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        grip.setAccessibilityLabel("Resize panel")
        grip.setAccessibilityHelp("Drag to resize the Kodros Orb panel.")
        grip.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleResizeDrag(_:))))
        product.resizeGrip = grip
        bottomBar.addSubview(grip)
    }

    // Recomputes every expanded-view frame from the live panel size.
    // Masks keep drags smooth; this pass is the deterministic fix for any
    // desync after collapse/expand cycles or interrupted gestures.
    func layoutExpandedSubviews() {
        guard expanded else { return }
        let W = containerView.bounds.width, H = containerView.bounds.height
        let topH: CGFloat = 52, inputH: CGFloat = 52, bottomH: CGFloat = 28, pad: CGFloat = 12
        materialView.frame = containerView.bounds
        topBar.frame = NSRect(x: 0, y: H - topH, width: W, height: topH)
        product.toolsButton?.frame = NSRect(x: W - 114, y: 12, width: 28, height: 28)
        lookBtn.frame = NSRect(x: W - 78, y: 12, width: 28, height: 28)
        voiceBtn.frame = NSRect(x: W - 42, y: 12, width: 28, height: 28)
        product.activity.frame = NSRect(x: W - 138, y: 18, width: 14, height: 14)
        let outputY = inputH + bottomH
        let outputH = H - topH - outputY
        outputScroll.frame = NSRect(x: 0, y: outputY, width: W, height: outputH)
        outputTV.textContainer?.containerSize = NSSize(width: W - 20, height: CGFloat.greatestFiniteMagnitude)
        welcomeView.frame = outputScroll.frame
        for (i, sub) in welcomeView.subviews.enumerated() {
            switch i {
            case 0: sub.frame = NSRect(x: (W - 64) / 2, y: outputH / 2 + 50, width: 64, height: 64)
            case 1: sub.frame = NSRect(x: 40, y: outputH / 2 + 24, width: W - 80, height: 16)
            case 2: sub.frame = NSRect(x: 40, y: outputH / 2 - 14, width: W - 80, height: 26)
            case 3: sub.frame = NSRect(x: 40, y: outputH / 2 - 42, width: W - 80, height: 20)
            default:
                let chip = CGFloat(welcomeView.subviews.count - 4)
                let total = 116 * chip + 8 * (chip - 1)
                sub.frame = NSRect(x: (W - total) / 2 + CGFloat(i - 4) * 124, y: outputH / 2 - 84, width: 116, height: 32)
            }
        }
        inputBar.frame = NSRect(x: 0, y: bottomH, width: W, height: inputH)
        inputField.frame = NSRect(x: pad, y: 8, width: W - pad * 2 - 48, height: 36)
        sendBtn.frame = NSRect(x: W - pad - 36, y: 8, width: 36, height: 36)
        bottomBar.frame = NSRect(x: 0, y: 0, width: W, height: bottomH)
        modelLabel.frame = NSRect(x: W - 220, y: 6, width: 164, height: 16)
        // Its mask leaves both horizontal margins flexible, so AppKit splits every
        // width delta between them and the label creeps rightward across resize and
        // collapse cycles. Restate the fixed slot beside the connection label.
        product.characterLabel.frame = NSRect(x: 146, y: 6, width: 92, height: 16)
        product.resizeGrip?.frame = NSRect(x: W - 28, y: 0, width: 28, height: 28)
    }

    // A resize drag is not the only way a session ends. launchd sends SIGTERM on
    // kickstart, and a quit taken while expanded never passes through a drag, so
    // writing the size only at drag end loses it. Collapse and terminate call this
    // too. Guarded on `expanded` because a collapsed panel's frame is the orb.
    func savePanelGeometry() {
        guard expanded else { return }
        UserDefaults.standard.set([panel.frame.width, panel.frame.height], forKey: "panel.size")
    }

    @objc func handleResizeDrag(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            product.resizeStart = (NSEvent.mouseLocation, panel.frame)
        case .changed:
            let mouse = NSEvent.mouseLocation
            let start = product.resizeStart
            let w = max(360, min(start.frame.width + mouse.x - start.mouse.x, 1000))
            let h = max(400, min(start.frame.height - (mouse.y - start.mouse.y), 1200))
            panel.setFrame(NSRect(x: start.frame.minX, y: start.frame.maxY - h, width: w, height: h), display: true)
        case .ended, .cancelled:
            layoutExpandedSubviews()
            clampPanelToScreen()
            savePanelGeometry()
        default: break
        }
    }

    private func configureUpgradeViews() {
        guard let toolsButton = product.toolsButton else { return }
        product.activity.style = .spinning
        product.activity.controlSize = .small
        product.activity.frame = NSRect(x: 302, y: 18, width: 14, height: 14)
        product.activity.isDisplayedWhenStopped = false
        topBar.addSubview(product.activity)
        statusLabel.frame.size.width = 218

        product.characterLabel.font = kUIFontSmall
        product.characterLabel.textColor = kDim
        product.characterLabel.alignment = .center
        product.characterLabel.frame = NSRect(x: 146, y: 6, width: 92, height: 16)
        bottomBar.addSubview(product.characterLabel)

        outputTV.font = NSFont.systemFont(ofSize: product.textSize)
        outputTV.usesFindBar = true
        outputTV.isAutomaticLinkDetectionEnabled = true
        outputTV.isAutomaticDataDetectionEnabled = true
        outputTV.isAutomaticSpellingCorrectionEnabled = false
        inputField.maximumNumberOfLines = 1
        inputField.setAccessibilityLabel("Message")
        inputField.setAccessibilityHelp("Type a message or a slash command. The limit is 8,000 characters.")
        // No system focus ring: the composer uses its own white border
        // (see controlTextDidBeginEditing) so the panel stays monochrome.
        inputField.focusRingType = .none
        configureComposerMenu()

        collapseBtn.setAccessibilityLabel("Collapse Kodros Orb")
        collapseBtn.setAccessibilityHelp("Collapse the panel to the floating orb.")
        toolsButton.setAccessibilityHelp("Open window, conversation, appearance, and quick-action tools.")
        lookBtn.setAccessibilityLabel("Share screen with Kodros Orb")
        lookBtn.setAccessibilityHelp("Capture the display under the pointer and send the image to Kodros Orb.")
        voiceBtn.setAccessibilityLabel("Start or stop voice mode")
        voiceBtn.setAccessibilityHelp("Use the microphone and speech recognition for a voice conversation.")
        sendBtn.setAccessibilityLabel("Send message")
        sendBtn.setAccessibilityHelp("Send the current message to Kodros Orb.")
        orb.setAccessibilityLabel("Kodros Orb")
        smallOrb.setAccessibilityLabel("Kodros Orb voice status")
        statusLabel.setAccessibilityLabel("Kodros Orb status")
        connLabel.setAccessibilityLabel("Connection status")
        modelLabel.setAccessibilityLabel("Current model")
        modelLabel.toolTip = "Click to copy the full model identifier"
        connLabel.toolTip = "Click to reconnect"
        connLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(reconnectRuntime)))
        modelLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(copyModelIdentifier)))
        inputField.nextKeyView = sendBtn
        sendBtn.nextKeyView = lookBtn
        lookBtn.nextKeyView = voiceBtn
        voiceBtn.nextKeyView = toolsButton
        toolsButton.nextKeyView = inputField
        updateComposerState()
    }

    private func configureComposerMenu() {
        let menu = NSMenu(title: "Composer")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Paste as Plain Text", #selector(pastePlainText)))
        menu.addItem(menuItem("Clear Composer", #selector(clearComposer)))
        menu.addItem(.separator())
        for command in slashCommands.prefix(8) {
            let item = NSMenuItem(title: command, action: #selector(insertSlashCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            menu.addItem(item)
        }
        inputField.menu = menu
    }

    private func buildUpgradeMenus(in menu: NSMenu?) {
        guard let menu else { return }
        menu.addItem(.separator())
        menu.addItem(submenu("Window", [
            menuItem("Keep Above Other Windows", #selector(togglePinned), state: product.pinned),
            menuItem("Center on Display", #selector(centerPanel)),
            menuItem("Move to Next Display", #selector(moveToNextDisplay)),
            menuItem("Reset Position", #selector(resetPanelPosition)),
            .separator(),
            menuItem("Snap Left", #selector(snapLeft)), menuItem("Snap Right", #selector(snapRight)),
            menuItem("Snap Top", #selector(snapTop)), menuItem("Snap Bottom", #selector(snapBottom)),
            menuItem("Snap Top Left", #selector(snapTopLeft)), menuItem("Snap Top Right", #selector(snapTopRight)),
            menuItem("Snap Bottom Left", #selector(snapBottomLeft)), menuItem("Snap Bottom Right", #selector(snapBottomRight)),
        ]))
        menu.addItem(submenu("Conversation", [
            menuItem("Copy Latest Response", #selector(copyLatestResponse)),
            menuItem("Copy Conversation", #selector(copyConversation)),
            menuItem("Export Conversation…", #selector(exportConversation)),
            menuItem("Restore Cleared Conversation", #selector(restoreClearedConversation)),
            menuItem("Find…", #selector(showConversationFind)),
            .separator(),
            menuItem("Larger Text", #selector(increaseConversationText)),
            menuItem("Smaller Text", #selector(decreaseConversationText)),
            menuItem("Reset Text Size", #selector(resetConversationText)),
            menuItem("Scroll to First Message", #selector(scrollConversationTop)),
            menuItem("Scroll to Latest Message", #selector(scrollConversationBottom)),
            .separator(),
            menuItem("Reuse Latest Prompt", #selector(reuseLatestPrompt)),
            menuItem("Retry Latest Prompt", #selector(retryLatestPrompt)),
            menuItem("Speak Latest Response", #selector(speakLatestResponse)),
            menuItem("Stop Speaking", #selector(stopSpeakingNow)),
        ]))
        menu.addItem(submenu("Quick Prompts", [
            menuItem("Summarize This Screen", #selector(quickScreenSummary)),
            menuItem("What Needs My Attention?", #selector(quickAttentionSummary)),
            menuItem("Draft a Reply", #selector(quickDraftReply)),
        ]))
        menu.addItem(submenu("Appearance", [
            appearanceItem("System", value: "system"), appearanceItem("Light", value: "light"), appearanceItem("Dark", value: "dark"),
            .separator(),
            menuItem("High Contrast", #selector(toggleHighContrast), state: product.highContrast),
            menuItem("Solid Background", #selector(toggleSolidBackground), state: product.solidBackground),
            .separator(),
            opacityItem("100% Opacity", value: 1), opacityItem("95% Opacity", value: 0.95), opacityItem("90% Opacity", value: 0.9),
            menuItem("Show Timestamps", #selector(toggleTimestamps), state: product.timestamps),
        ]))
        menu.addItem(.separator())
        menu.addItem(submenu("Privacy", [
            menuItem("Open Screen Recording Settings", #selector(openScreenRecordingSettings)),
            menuItem("Open Microphone Settings", #selector(openMicrophoneSettings)),
            menuItem("Open Speech Recognition Settings", #selector(openSpeechSettings)),
        ]))
        menu.addItem(menuItem("Restart Kodros Orb", #selector(restartApp)))
        menu.addItem(menuItem("Abort Current Action", #selector(abortCurrentAction)))
        menu.addItem(menuItem("Reconnect Runtime", #selector(reconnectRuntime)))
        menu.addItem(menuItem("Open WebUI Workspace", #selector(openOpenWebUI)))
        menu.addItem(menuItem("100 Product Upgrades", #selector(showUpgradeCatalog)))
    }

    private func menuItem(_ title: String, _ action: Selector, state: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title)
        items.forEach(child.addItem)
        parent.submenu = child
        return parent
    }

    private func appearanceItem(_ title: String, value: String) -> NSMenuItem {
        let item = menuItem(title, #selector(selectAppearance(_:)), state: product.appearance == value)
        item.representedObject = value
        return item
    }

    // MARK: - Welcome suggestion chips

    // Three monochrome pills under the welcome subtitle. Each routes to an
    // existing quick action; they hide with the welcome view.
    func installWelcomeChips() {
        let chips: [(String, String, Selector)] = [
            ("eye", "Screen", #selector(quickScreenSummary)),
            ("magnifyingglass", "Vault", #selector(qVault)),
            ("terminal", "Terminal", #selector(qBash)),
        ]
        let chipW: CGFloat = 116, chipH: CGFloat = 32, gap: CGFloat = 8
        let total = chipW * 3 + gap * 2
        let startX = (panelW - total) / 2
        let y = welcomeView.frame.height / 2 - 84
        for (i, (symbol, title, action)) in chips.enumerated() {
            let chip = NSButton(frame: NSRect(x: startX + CGFloat(i) * (chipW + gap), y: y, width: chipW, height: chipH))
            chip.isBordered = false
            chip.wantsLayer = true
            chip.layer?.backgroundColor = kSurface.withAlphaComponent(0.72).cgColor
            chip.layer?.cornerRadius = 12
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = kBorder.cgColor
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            chip.image = image
            chip.imagePosition = .imageLeading
            chip.imageHugsTitle = true
            chip.contentTintColor = kDim
            chip.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: kText,
            ])
            chip.target = self
            chip.action = action
            chip.autoresizingMask = [.minXMargin, .maxXMargin]
            chip.toolTip = title == "Screen" ? "Summarize the display under the pointer"
                : title == "Vault" ? "Prefill a vault search" : "Prefill a local command"
            welcomeView.addSubview(chip)
        }
        // Clicking the hero orb focuses the composer.
        if let hero = welcomeView.subviews.compactMap({ $0 as? OrbView }).first {
            let click = NSClickGestureRecognizer(target: self, action: #selector(focusComposerFromWelcome))
            hero.addGestureRecognizer(click)
        }
    }

    @objc func focusComposerFromWelcome() {
        panel.makeKey()
        inputField.window?.makeFirstResponder(inputField)
    }

    private func opacityItem(_ title: String, value: Double) -> NSMenuItem {
        let item = menuItem(title, #selector(selectOpacity(_:)), state: abs(product.opacity - value) < 0.001)
        item.representedObject = value
        return item
    }

    private func installUpgradeKeyboardRouter() {
        product.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleUpgradeKey(event) == true ? nil : event
        }
    }

    private func installDisplayObservers() {
        product.screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.clampPanelToScreen() }
        product.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clampPanelToScreen()
            if self?.pi.isRunning == false { self?.reconnectRuntime() }
        }
    }
}

// Bottom-right resize handle. Three diagonal dots, crosshair cursor.
final class ResizeGripView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        kDim.withAlphaComponent(0.55).setFill()
        for i in 0..<3 {
            let o = CGFloat(i) * 6
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 7 - o, y: 5 + o, width: 3, height: 3)).fill()
        }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
