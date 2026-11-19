import Cocoa
import AVFoundation
import Speech
// MARK: - App delegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                          AVSpeechSynthesizerDelegate, NSTextFieldDelegate {
    var panel: NSPanel!
    var orb, smallOrb: OrbView!
    var expanded = false
    var containerView, topBar, welcomeView, inputBar, bottomBar, connDot: NSView!
    var materialView: NSVisualEffectView!
    var statusLabel: NSTextField!
    var lookBtn, voiceBtn, collapseBtn: NSButton!
    var outputScroll: NSScrollView!
    var outputTV: NSTextView!
    var inputField: NSTextField!
    var sendBtn: NSButton!
    var connLabel, modelLabel: NSTextField!
    let product = ProductState()
    let pi = PiClient()
    let engine = AVAudioEngine()
    var recognizer: SFSpeechRecognizer?
    var recogRequest: SFSpeechAudioBufferRecognitionRequest?
    var recogTask: SFSpeechRecognitionTask?
    let synth = AVSpeechSynthesizer()
    var sessionActive = false
    var transcript = ""
    var lastTranscriptChange = Date()
    var endpointTimer: Timer?
    var stopping = false
    var monitoringBarge = false
    var bargeFrames = 0
    var followClicks = UserDefaults.standard.bool(forKey: "orb.followClicks")
    var globalClickMonitor: Any?
    var followClicksMenuItem: NSMenuItem?
    var lastDragEnd = Date.distantPast
    private var dragAccum: CGFloat = 0
    private var dragStart = (mouse: NSPoint.zero, origin: NSPoint.zero)
    var commandHistory: [String] = []
    var historyIndex = -1
    var isRunningCommand = false
    var activeProcesses: [Process] = []
    var defaultModel: (provider: String, id: String)?
    var waitingForPi = false
    let orbSize: CGFloat = 88
    let panelW: CGFloat = 440
    let panelH: CGFloat = 500
    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        synth.delegate = self
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: orbSize, height: orbSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        containerView = NSView(frame: NSRect(x: 0, y: 0, width: orbSize, height: orbSize))
        containerView.wantsLayer = true
        panel.contentView = containerView
        orb = OrbView(frame: containerView.bounds)
        orb.autoresizingMask = [.width, .height]
        containerView.addSubview(orb)
        let click = NSClickGestureRecognizer(target: self, action: #selector(orbClicked))
        orb.addGestureRecognizer(click)
        orb.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:))))
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Panel (\(AppDelegate.summonHotKeyLabel))",
                     action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Voice", action: #selector(toggleVoiceMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Look at Screen", action: #selector(lookAtScreen), keyEquivalent: "")
        followClicksMenuItem = menu.addItem(withTitle: "Follow Clicks", action: #selector(toggleFollowClicks), keyEquivalent: "")
        followClicksMenuItem?.state = followClicks ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Brain: Kimi K3", action: #selector(useDefaultBrain), keyEquivalent: "")
        menu.addItem(withTitle: "Brain: Qwen 3.8", action: #selector(useQwenBrain), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Output", action: #selector(clearOutputAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Restart Kodros Orb", action: #selector(restartApp), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Kodros Orb", action: #selector(quit), keyEquivalent: "q")
        orb.menu = menu
        buildExpandedUI()
        restorePersistedTranscript()
        installSummonHotKey()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            var origin = NSPoint(x: f.maxX - orbSize - 28, y: f.minY + 28)
            if let saved = UserDefaults.standard.array(forKey: "orb.origin") as? [CGFloat], saved.count == 2 {
                let p = NSPoint(x: saved[0], y: saved[1])
                let rect = NSRect(origin: p, size: NSSize(width: orbSize, height: orbSize))
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                    origin = p
                }
            }
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async { self?.moveOrbNearPointer() }
        }

        pi.onEvent = { [weak self] event in self?.handlePiEvent(event) }
        pi.onLog = { [weak self] message in
            NSLog("Pi RPC: %@", message)
            DispatchQueue.main.async { self?.appendRuntimeLog(message) }
        }
        pi.onDisconnect = { [weak self] in
            DispatchQueue.main.async {
                self?.appendOutput("[system] Kodros Orb disconnected. Reconnect is scheduled.", color: kYellow)
                self?.updateConnectionStatus()
                self?.scheduleRuntimeReconnect()
            }
        }
        do {
            try pi.start()
        } catch {
            appendOutput("[system] Failed to start Kodros Orb: \(error)", color: kRed)
            scheduleRuntimeReconnect()
        }

        pi.send(["type": "set_thinking_level", "level": "high"], timeout: 10) { _ in }
        pi.send(["type": "set_auto_retry", "enabled": true], timeout: 10) { _ in }
        pi.send(["type": "get_state"], timeout: 10) { [weak self] r in
            if case .success(let o) = r,
               let d = o["data"] as? [String: Any],
               let m = d["model"] as? [String: Any] {
                self?.defaultModel = (m["provider"] as? String ?? "", m["id"] as? String ?? "")
                DispatchQueue.main.async { self?.updateModelLabel() }
            }
        }

        endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkEndpoint()
        }
        updateConnectionStatus()
    }

    // MARK: - Build expanded UI
    func buildExpandedUI() {
        let W = panelW
        let topH: CGFloat = 52
        let inputH: CGFloat = 52
        let bottomH: CGFloat = 28
        let pad: CGFloat = 12

        materialView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: panelH))
        materialView.material = .underWindowBackground
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        materialView.wantsLayer = true
        let materialOpacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.96
        materialView.layer?.backgroundColor = kBg.withAlphaComponent(materialOpacity).cgColor
        materialView.layer?.cornerRadius = 18
        materialView.layer?.masksToBounds = true
        containerView.addSubview(materialView)

        topBar = NSView(frame: NSRect(x: 0, y: panelH - topH, width: W, height: topH))
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(topBar)

        let dragView = NSView(frame: topBar.bounds)
        dragView.wantsLayer = true
        let dragGesture = NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        dragView.addGestureRecognizer(dragGesture)
        topBar.addSubview(dragView)

        collapseBtn = NSButton(title: "", target: self, action: #selector(collapsePanel))
        collapseBtn.bezelStyle = .inline
        collapseBtn.isBordered = false
        collapseBtn.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Collapse")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        collapseBtn.imageScaling = .scaleNone
        collapseBtn.contentTintColor = NSColor(calibratedRed: 1, green: 0.373, blue: 0.341, alpha: 1)
        collapseBtn.frame = NSRect(x: 8, y: 12, width: 28, height: 28)
        collapseBtn.toolTip = "Collapse to orb"
        topBar.addSubview(collapseBtn)

        smallOrb = OrbView(frame: NSRect(x: 38, y: 8, width: 36, height: 36))
        topBar.addSubview(smallOrb)
        let orbClick = NSClickGestureRecognizer(target: self, action: #selector(voiceToggleClicked))
        smallOrb.addGestureRecognizer(orbClick)

        statusLabel = makeLabel("Kodros Orb · ready", font: kUIFont, color: kText)
        statusLabel.frame = NSRect(x: 78, y: 16, width: 230, height: 20)
        statusLabel.lineBreakMode = .byTruncatingTail
        topBar.addSubview(statusLabel)

        let toolsButton = NSPopUpButton(frame: NSRect(x: W - 114, y: 12, width: 28, height: 28), pullsDown: true)
        toolsButton.bezelStyle = .inline
        toolsButton.isBordered = false
        (toolsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        toolsButton.addItem(withTitle: "")
        toolsButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Tools")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        toolsButton.imageScaling = .scaleProportionallyDown
        toolsButton.contentTintColor = kText
        toolsButton.setAccessibilityLabel("Tools")
        toolsButton.toolTip = "Tools (Command-K)"
        toolsButton.menu?.addItem(.separator())
        for (title, action) in [("Search Vault", #selector(qVault)), ("Local Terminal", #selector(qBash)), ("SSH to remote-host", #selector(qSSH)), ("Search Graph", #selector(qGraph))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            toolsButton.menu?.addItem(item)
        }
        toolsButton.menu?.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear Conversation", action: #selector(clearOutputAction), keyEquivalent: "")
        clearItem.target = self
        toolsButton.menu?.addItem(clearItem)
        topBar.addSubview(toolsButton)

        lookBtn = NSButton(title: "", target: self, action: #selector(lookAtScreen))
        lookBtn.bezelStyle = .inline
        lookBtn.isBordered = false
        lookBtn.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Look at screen")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        lookBtn.imageScaling = .scaleProportionallyDown
        lookBtn.contentTintColor = kAccent
        lookBtn.frame = NSRect(x: W - 78, y: 12, width: 28, height: 28)
        lookBtn.toolTip = "Share this display with Kodros Orb"
        topBar.addSubview(lookBtn)

        voiceBtn = NSButton(title: "", target: self, action: #selector(voiceToggleClicked))
        voiceBtn.bezelStyle = .inline
        voiceBtn.isBordered = false
        voiceBtn.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Voice mode")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        voiceBtn.imageScaling = .scaleProportionallyDown
        voiceBtn.contentTintColor = kDim
        voiceBtn.frame = NSRect(x: W - 42, y: 12, width: 28, height: 28)
        voiceBtn.toolTip = "Toggle voice mode"
        topBar.addSubview(voiceBtn)

        let outputY = inputH + bottomH
        let outputH = panelH - topH - outputY
        outputScroll = NSScrollView(frame: NSRect(x: 0, y: outputY, width: W, height: outputH))
        outputScroll.hasVerticalScroller = true
        outputScroll.hasHorizontalScroller = false
        outputScroll.autohidesScrollers = true
        outputScroll.borderType = .noBorder
        outputScroll.drawsBackground = false
        containerView.addSubview(outputScroll)

        outputTV = NSTextView(frame: NSRect(x: 0, y: 0, width: W, height: outputH))
        outputTV.isEditable = false
        outputTV.isSelectable = true
        outputTV.drawsBackground = false
        outputTV.textColor = kText
        outputTV.font = kChatFont
        outputTV.textContainerInset = NSSize(width: 16, height: 14)
        outputTV.isVerticallyResizable = true
        outputTV.isHorizontallyResizable = false
        outputTV.autoresizingMask = [.width]
        outputTV.textContainer?.widthTracksTextView = true
        outputTV.textContainer?.containerSize = NSSize(width: W - 20, height: CGFloat.greatestFiniteMagnitude)
        outputScroll.documentView = outputTV

        welcomeView = NSView(frame: outputScroll.frame)
        let heroOrb = OrbView(frame: NSRect(x: (W - 64) / 2, y: outputH / 2 + 50, width: 64, height: 64))
        welcomeView.addSubview(heroOrb)
        let eyebrow = makeLabel("KODROS", font: NSFont.systemFont(ofSize: 10, weight: .bold), color: kAccent)
        eyebrow.attributedStringValue = NSAttributedString(string: "KODROS", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: kAccent, .kern: 2.5])
        eyebrow.alignment = .center
        eyebrow.frame = NSRect(x: 40, y: outputH / 2 + 24, width: W - 80, height: 16)
        welcomeView.addSubview(eyebrow)
        let welcomeTitle = makeLabel("What can I help with?", font: kTitleFont, color: kText)
        welcomeTitle.alignment = .center
        welcomeTitle.frame = NSRect(x: 40, y: outputH / 2 - 14, width: W - 80, height: 26)
        welcomeView.addSubview(welcomeTitle)
        let welcomeBody = makeLabel("Ask anything, speak, or share your screen.", font: NSFont.systemFont(ofSize: 13), color: kDim)
        welcomeBody.alignment = .center
        welcomeBody.frame = NSRect(x: 40, y: outputH / 2 - 42, width: W - 80, height: 20)
        welcomeView.addSubview(welcomeBody)
        containerView.addSubview(welcomeView)

        inputBar = NSView(frame: NSRect(x: 0, y: bottomH, width: W, height: inputH))
        inputBar.wantsLayer = true
        inputBar.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(inputBar)

        inputField = NSTextField(frame: NSRect(x: pad, y: 8, width: W - pad * 2 - 48, height: 36))
        inputField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        inputField.textColor = kText
        inputField.drawsBackground = true
        inputField.backgroundColor = kSurface.withAlphaComponent(0.78)
        inputField.wantsLayer = true
        inputField.layer?.cornerRadius = 10
        inputField.layer?.borderWidth = 1
        inputField.layer?.borderColor = kBorder.cgColor
        inputField.placeholderAttributedString = NSAttributedString(string: "Ask Kodros Orb anything…", attributes: [.foregroundColor: kDim, .font: NSFont.systemFont(ofSize: 14)])
        inputField.delegate = self
        inputField.focusRingType = .none
        inputBar.addSubview(inputField)

        sendBtn = NSButton(title: "", target: self, action: #selector(sendClicked))
        sendBtn.isBordered = false
        sendBtn.wantsLayer = true
        sendBtn.layer?.backgroundColor = kAccent.cgColor
        sendBtn.layer?.cornerRadius = 11
        sendBtn.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        sendBtn.imageScaling = .scaleProportionallyDown
        sendBtn.contentTintColor = kOnAccent
        sendBtn.frame = NSRect(x: W - pad - 36, y: 8, width: 36, height: 36)
        sendBtn.toolTip = "Send (Enter)"
        inputBar.addSubview(sendBtn)

        bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: W, height: bottomH))
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(bottomBar)

        connDot = NSView(frame: NSRect(x: pad, y: 10, width: 8, height: 8))
        connDot.wantsLayer = true
        connDot.layer?.cornerRadius = 5
        connDot.layer?.backgroundColor = kYellow.cgColor
        bottomBar.addSubview(connDot)

        connLabel = makeLabel("connecting…", font: kUIFontSmall, color: kDim)
        connLabel.frame = NSRect(x: 26, y: 6, width: 120, height: 16)
        bottomBar.addSubview(connLabel)

        modelLabel = makeLabel("", font: kUIFontSmall, color: kDim)
        modelLabel.alignment = .right
        modelLabel.frame = NSRect(x: W - 200, y: 6, width: 188, height: 16)
        bottomBar.addSubview(modelLabel)

        installProductUpgrades(to: toolsButton)
        installWelcomeChips()
        setExpandedViewsHidden(true)

        showWelcome()
    }

    func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.drawsBackground = false
        l.isBordered = false
        l.isEditable = false
        return l
    }

    func setExpandedViewsHidden(_ hidden: Bool) {
        for v in [materialView!, topBar!, outputScroll!, inputBar!, bottomBar!] { v.isHidden = hidden }
        welcomeView.isHidden = hidden || !outputTV.string.isEmpty
    }

    // MARK: - Expand / Collapse
    @objc func togglePanel() {
        if expanded { collapsePanel() } else { expandPanel() }
    }

    func expandPanel() {
        guard !expanded else { return }
        expanded = true

        let oldFrame = panel.frame
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let saved = UserDefaults.standard.array(forKey: "panel.size") as? [CGFloat]
        let w = saved?.count == 2 ? saved![0] : panelW, h = saved?.count == 2 ? saved![1] : panelH

        var newX = oldFrame.maxX - w
        var newY = oldFrame.maxY - h

        if newX < screen.minX + 8 { newX = screen.minX + 8 }
        if newY < screen.minY + 8 { newY = screen.minY + 8 }
        if newX + w > screen.maxX - 8 { newX = screen.maxX - 8 - w }
        if newY + h > screen.maxY - 8 { newY = screen.maxY - 8 - h }

        let newFrame = NSRect(x: newX, y: newY, width: w, height: h)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(newFrame, display: true)
        }) { [weak self] in
            guard let self else { return }
            self.panel.hasShadow = true
            self.panel.isOpaque = false
            self.containerView.layer?.backgroundColor = NSColor.clear.cgColor
            self.containerView.layer?.cornerRadius = 18
            self.containerView.layer?.borderWidth = 1
            self.containerView.layer?.borderColor = kBorder.cgColor
            self.containerView.layer?.masksToBounds = true
            self.orb.isHidden = true
            self.setExpandedViewsHidden(false)
            self.layoutExpandedSubviews()
            self.panel.makeKey()
            self.inputField.window?.makeFirstResponder(self.inputField)
            self.updateConnectionStatus()
        }
    }

    @objc func collapsePanel() {
        guard expanded else { return }
        savePanelGeometry()
        expanded = false
        inputField.window?.makeFirstResponder(nil)

        let oldFrame = panel.frame
        let newX = oldFrame.maxX - orbSize
        let newY = oldFrame.maxY - orbSize
        let newFrame = NSRect(x: newX, y: newY, width: orbSize, height: orbSize)

        setExpandedViewsHidden(true)
        orb.isHidden = false
        containerView.layer?.cornerRadius = 0
        containerView.layer?.borderWidth = 0
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(newFrame, display: true)
        }) { [weak self] in
            self?.panel.hasShadow = false
        }
    }

    // MARK: - Drag
    @objc func handleDrag(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragAccum = 0
            let (mouse, initial) = (NSEvent.mouseLocation, gesture.translation(in: gesture.view))
            dragStart = (NSPoint(x: mouse.x - initial.x, y: mouse.y - initial.y), panel.frame.origin)
        case .changed:
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - dragStart.mouse.x
            let dy = mouse.y - dragStart.mouse.y
            dragAccum = abs(dx) + abs(dy)
            var origin = NSPoint(x: dragStart.origin.x + dx, y: dragStart.origin.y + dy)
            let scale = panel.backingScaleFactor
            origin.x = (origin.x * scale).rounded() / scale
            origin.y = (origin.y * scale).rounded() / scale
            panel.setFrameOrigin(origin)
        case .ended, .cancelled:
            if dragAccum > 6 {
                lastDragEnd = Date()
                clampPanelToScreen()
                saveOrbPosition()
            } else if !expanded, gesture.view === orb {
                // The pan recognizer cancels clicks after a few points of
                // hand drift. Treat a tiny drag on the orb as a click.
                orbClicked()
            }
        default: break
        }
    }

    func clampPanelToScreen() {
        let f = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var o = f.origin
        o.x = min(max(o.x, v.minX + 4), v.maxX - f.width - 4)
        o.y = min(max(o.y, v.minY + 4), v.maxY - f.height - 4)
        if o != f.origin { panel.setFrameOrigin(o) }
    }

    func saveOrbPosition() {
        guard !expanded else { return }
        let o = panel.frame.origin
        UserDefaults.standard.set([o.x, o.y], forKey: "orb.origin")
    }

    // MARK: - Pointer placement
    @objc func toggleFollowClicks() {
        followClicks.toggle()
        followClicksMenuItem?.state = followClicks ? .on : .off
        UserDefaults.standard.set(followClicks, forKey: "orb.followClicks")
    }

    func moveOrbNearPointer() {
        guard followClicks, !expanded else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
        let frame = screen.visibleFrame
        let x = min(max(point.x + 14, frame.minX + 8), frame.maxX - orbSize - 8)
        let y = min(max(point.y - orbSize - 14, frame.minY + 8), frame.maxY - orbSize - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Orb click
    @objc func orbClicked() {
        if Date().timeIntervalSince(lastDragEnd) < 0.25 { return }
        if !expanded {
            expandPanel()
            return
        }
        toggleVoiceSession()
    }

}
