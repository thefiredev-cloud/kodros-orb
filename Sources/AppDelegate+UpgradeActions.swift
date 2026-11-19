import Cocoa

extension AppDelegate {
    @objc func openOpenWebUI() {
        guard let url = URL(string: "http://127.0.0.1:8080/"), NSWorkspace.shared.open(url) else {
            appendOutput("[Open WebUI] Local workspace is not available at 127.0.0.1:8080.", color: kYellow)
            return
        }
        appendOutput("[system] Opened Open WebUI workspace.", color: kGreen)
    }

    var slashCommands: [String] {
        ["/help", "/clear", "/voice", "/look ", "/vault search ", "/graphify ", "/model ", "/abort", "/collapse"]
    }

    func controlTextDidChange(_ notification: Notification) {
        (inputField.currentEditor() as? NSTextView)?.insertionPointColor = kAccent
        updateComposerState()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        inputField.layer?.borderColor = kAccent.cgColor
        inputField.layer?.borderWidth = product.highContrast ? 2 : 1.5
        if let editor = inputField.currentEditor() as? NSTextView {
            editor.insertionPointColor = kAccent
            editor.isContinuousSpellCheckingEnabled = true
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        inputField.layer?.borderColor = kBorder.cgColor
        inputField.layer?.borderWidth = product.highContrast ? 2 : 1
    }

    func updateComposerState() {
        if inputField.stringValue.count > 8_000 { inputField.stringValue = String(inputField.stringValue.prefix(8_000)) }
        let count = inputField.stringValue.count
        product.characterLabel.stringValue = "\(count.formatted()) / 8,000"
        product.characterLabel.textColor = count > 7_200 ? kYellow : kDim
        sendBtn.isEnabled = !inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendBtn.alphaValue = sendBtn.isEnabled ? 1 : 0.42
        inputField.setAccessibilityValue("\(count) of 8,000 characters")
        UserDefaults.standard.set(inputField.stringValue, forKey: "product.draft")
    }

    func restoreComposerDraft() {
        inputField.stringValue = UserDefaults.standard.string(forKey: "product.draft") ?? ""
        commandHistory = UserDefaults.standard.stringArray(forKey: "command.history") ?? []
        updateComposerState()
    }

    @objc func pastePlainText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if let editor = inputField.currentEditor() as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            inputField.stringValue += text
        }
        updateComposerState()
    }

    @objc func clearComposer() {
        inputField.stringValue = ""
        updateComposerState()
        panel.makeKey()
        inputField.window?.makeFirstResponder(inputField)
    }

    @objc func insertSlashCommand(_ sender: NSMenuItem) {
        inputField.stringValue = sender.representedObject as? String ?? ""
        updateComposerState()
        panel.makeKey()
        inputField.window?.makeFirstResponder(inputField)
    }

    func completeSlashCommand() -> Bool {
        guard let match = SlashCommandCompletion.complete(inputField.stringValue, from: slashCommands) else {
            return false
        }
        inputField.stringValue = match
        updateComposerState()
        return true
    }

    func handleUpgradeKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Plain Escape collapses from anywhere in the panel, matching the
        // composer's own cancelOperation path.
        if event.keyCode == 53, flags.isEmpty, expanded { collapsePanel(); return true }
        guard flags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.shift) {
            switch key {
            case "c": copyLatestResponse(); return true
            case "r": retryLatestPrompt(); return true
            case "p": togglePinned(); return true
            default: return false
            }
        }
        switch key {
        case "l": panel.makeKey(); inputField.window?.makeFirstResponder(inputField); return true
        case "k": product.toolsButton?.performClick(nil); return true
        case "f": showConversationFind(); return true
        case "v": return pasteImageFromPasteboard() // false falls through to a normal text paste
        case ".": abortCurrentAction(); return true
        case "=", "+": increaseConversationText(); return true
        case "-": decreaseConversationText(); return true
        case "0": resetConversationText(); return true
        default:
            if event.keyCode == 36 { sendClicked(); return true }
            return false
        }
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        product.appearance = sender.representedObject as? String ?? "system"
        UserDefaults.standard.set(product.appearance, forKey: "product.appearance")
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        applyProductAppearance()
    }

    @objc func selectOpacity(_ sender: NSMenuItem) {
        product.opacity = sender.representedObject as? Double ?? 1
        UserDefaults.standard.set(product.opacity, forKey: "product.opacity")
        sender.menu?.items.filter { $0.representedObject is Double }.forEach { $0.state = $0 === sender ? .on : .off }
        applyProductAppearance()
    }

    @objc func toggleHighContrast(_ sender: NSMenuItem? = nil) {
        product.highContrast.toggle()
        UserDefaults.standard.set(product.highContrast, forKey: "product.highContrast")
        sender?.state = product.highContrast ? .on : .off
        applyProductAppearance()
    }

    @objc func toggleSolidBackground(_ sender: NSMenuItem? = nil) {
        product.solidBackground.toggle()
        UserDefaults.standard.set(product.solidBackground, forKey: "product.solidBackground")
        sender?.state = product.solidBackground ? .on : .off
        applyProductAppearance()
    }

    @objc func toggleTimestamps(_ sender: NSMenuItem? = nil) {
        product.timestamps.toggle()
        UserDefaults.standard.set(product.timestamps, forKey: "product.timestamps")
        sender?.state = product.timestamps ? .on : .off
    }

    func applyProductAppearance() {
        switch product.appearance {
        case "light": panel.appearance = NSAppearance(named: .aqua)
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        default: panel.appearance = nil
        }
        panel.alphaValue = product.opacity
        materialView.material = product.solidBackground ? .contentBackground : .underWindowBackground
        materialView.state = product.solidBackground ? .inactive : .active
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            materialView.layer?.backgroundColor = kBg.withAlphaComponent(product.solidBackground ? 1 : 0.96).cgColor
            // The card border belongs to the expanded panel only — the
            // collapsed orb is frameless.
            containerView.layer?.borderColor = (product.highContrast ? kText.withAlphaComponent(0.45) : kBorder).cgColor
            containerView.layer?.borderWidth = expanded ? (product.highContrast ? 2 : 1) : 0
            inputField.backgroundColor = kSurface.withAlphaComponent(product.solidBackground ? 1 : 0.82)
            inputField.layer?.borderColor = (product.highContrast ? kText.withAlphaComponent(0.45) : kBorder).cgColor
            inputField.layer?.borderWidth = product.highContrast ? 2 : 1
            sendBtn.layer?.backgroundColor = kAccent.cgColor
            outputTV.textColor = kText
        }
    }

    @objc func togglePinned(_ sender: NSMenuItem? = nil) {
        product.pinned.toggle()
        UserDefaults.standard.set(product.pinned, forKey: "product.pinned")
        sender?.state = product.pinned ? .on : .off
        applyPinnedState()
    }

    func applyPinnedState() { panel.level = product.pinned ? .floating : .normal }

    private func placePanel(horizontal: CGFloat, vertical: CGFloat) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let frame = panel.frame
        let x = area.minX + (area.width - frame.width) * horizontal
        let y = area.minY + (area.height - frame.height) * vertical
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if !expanded { saveOrbPosition() }
    }

    @objc func centerPanel() { placePanel(horizontal: 0.5, vertical: 0.5) }
    @objc func snapLeft() { placePanel(horizontal: 0, vertical: 0.5) }
    @objc func snapRight() { placePanel(horizontal: 1, vertical: 0.5) }
    @objc func snapTop() { placePanel(horizontal: 0.5, vertical: 1) }
    @objc func snapBottom() { placePanel(horizontal: 0.5, vertical: 0) }
    @objc func snapTopLeft() { placePanel(horizontal: 0, vertical: 1) }
    @objc func snapTopRight() { placePanel(horizontal: 1, vertical: 1) }
    @objc func snapBottomLeft() { placePanel(horizontal: 0, vertical: 0) }
    @objc func snapBottomRight() { placePanel(horizontal: 1, vertical: 0) }

    @objc func moveToNextDisplay() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        let current = panel.screen
        let index = screens.firstIndex { $0 === current } ?? 0
        let area = screens[(index + 1) % screens.count].visibleFrame.insetBy(dx: 12, dy: 12)
        panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width, y: area.maxY - panel.frame.height))
        if !expanded { saveOrbPosition() }
    }

    @objc func resetPanelPosition() {
        UserDefaults.standard.removeObject(forKey: "orb.origin")
        snapBottomRight()
    }

    func timestampPrefix() -> String {
        guard product.timestamps else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: Date()))  "
    }

    func snapshotConversationBeforeClear() {
        guard !outputTV.string.isEmpty else { return }
        product.clearedConversation = outputTV.attributedString()
    }

    @objc func restoreClearedConversation() {
        guard let saved = product.clearedConversation else { return }
        outputTV.textStorage?.setAttributedString(saved)
        welcomeView.isHidden = true
        scrollConversationBottom()
        savePersistedTranscript()
    }

    private func putOnPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyLatestResponse() { putOnPasteboard(product.lastResponse) }
    @objc func copyConversation() { putOnPasteboard(outputTV.string) }
    @objc func copyModelIdentifier() { putOnPasteboard(modelLabel.stringValue) }

    @objc func exportConversation() {
        guard !outputTV.string.isEmpty else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "Kodros-Orb-Conversation.txt"
        save.allowedContentTypes = [.plainText]
        save.beginSheetModal(for: panel) { [weak self] result in
            guard result == .OK, let url = save.url, let text = self?.outputTV.string else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.appendOutput("[error] The conversation export failed: \(error.localizedDescription)", color: kRed) }
        }
    }

    @objc func showConversationFind() {
        let sender = NSMenuItem()
        sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        outputTV.performFindPanelAction(sender)
    }

    private func setConversationTextSize(_ size: Double) {
        product.textSize = max(11, min(20, size))
        UserDefaults.standard.set(product.textSize, forKey: "product.textSize")
        outputTV.font = NSFont.systemFont(ofSize: product.textSize)
        let range = NSRange(location: 0, length: outputTV.string.utf16.count)
        outputTV.textStorage?.addAttribute(.font, value: NSFont.systemFont(ofSize: product.textSize), range: range)
    }

    @objc func increaseConversationText() { setConversationTextSize(product.textSize + 1) }
    @objc func decreaseConversationText() { setConversationTextSize(product.textSize - 1) }
    @objc func resetConversationText() { setConversationTextSize(13) }
    @objc func scrollConversationTop() { outputTV.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
    @objc func scrollConversationBottom() { outputTV.scrollToEndOfDocument(nil) }

    @objc func reuseLatestPrompt() {
        guard !product.lastPrompt.isEmpty else { return }
        inputField.stringValue = product.lastPrompt
        updateComposerState()
        panel.makeKey()
        inputField.window?.makeFirstResponder(inputField)
    }

    @objc func retryLatestPrompt() {
        guard !product.lastPrompt.isEmpty, !waitingForPi else { return }
        handleInput(product.lastPrompt)
    }

    @objc func speakLatestResponse() {
        let text = speakable(product.lastResponse)
        if !text.isEmpty { speak(text: text) }
    }

    @objc func stopSpeakingNow() {
        stopBargeMonitor()
        synth.stopSpeaking(at: .immediate)
        setOrbState(.idle)
    }

    @objc func abortCurrentAction() {
        pi.send(["type": "abort"]) { _ in }
        abortRunningCommands()
        waitingForPi = false
        clearStreamMarker(appendNewline: true)
        setOrbState(.idle)
        appendOutput("[system] The current action stopped.", color: kYellow)
    }

    @objc func reconnectRuntime() {
        product.reconnectWorkItem?.cancel()
        if pi.isRunning { pi.stop() }
        updateStatus("reconnecting…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startRuntimeReconnect() }
    }

    func scheduleRuntimeReconnect() {
        product.reconnectAttempt += 1
        let delay = min(pow(2, Double(product.reconnectAttempt - 1)), 30)
        updateStatus("reconnecting in \(Int(delay))s")
        let item = DispatchWorkItem { [weak self] in self?.startRuntimeReconnect() }
        product.reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func startRuntimeReconnect() {
        do {
            try pi.start()
            product.reconnectAttempt = 0
            updateConnectionStatus()
            updateStatus("ready")
        } catch {
            appendOutput("[system] The runtime reconnect failed: \(error.localizedDescription)", color: kYellow)
            scheduleRuntimeReconnect()
        }
    }

    @objc func quickScreenSummary() { captureAndAsk("Summarize this screen. Lead with what matters now.") }
    @objc func quickAttentionSummary() { captureAndAsk("What needs my attention on this screen? Give the top three items.") }
    @objc func quickDraftReply() { captureAndAsk("Draft a concise reply for the conversation on this screen. Do not send it.") }

    @objc func showUpgradeCatalog() {
        clearOutput()
        appendOutput("100 PRODUCT UPGRADES\n\n" + UpgradeCatalog.items.joined(separator: "\n"), color: kText, newline: true)
    }

    @objc func openScreenRecordingSettings() { openPrivacyPane("Privacy_ScreenCapture") }
    @objc func openMicrophoneSettings() { openPrivacyPane("Privacy_Microphone") }
    @objc func openSpeechSettings() { openPrivacyPane("Privacy_SpeechRecognition") }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func restartApp() {
        appendOutput("[system] Restarting. The launch agent brings Kodros Orb back in a moment.", color: kDim)
        applicationWillTerminate(Notification(name: Notification.Name("MeshOrbRestart")))
        // The launch agent relaunches only on a non-zero exit (KeepAlive SuccessfulExit=false).
        exit(1)
    }

    func updateProductActivity(for status: String) {
        let active = ["thinking", "listening", "speaking", "capturing", "looking", "running", "reconnecting"].contains { status.contains($0) }
        if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { product.activity.startAnimation(nil) }
        else { product.activity.stopAnimation(nil) }
        product.activity.isHidden = !active
        statusLabel.setAccessibilityValue(status)
    }

    func updateAccessibleConnection(_ connected: Bool) {
        connLabel.setAccessibilityValue(connected ? "Connected" : "Offline. Click to reconnect.")
        orb.setAccessibilityValue(connected ? "Ready and connected" : "Offline")
    }

    func coalescedOrbLevel(_ level: CGFloat) {
        let now = Date()
        guard now.timeIntervalSince(product.lastLevelUpdate) >= 1.0 / 30.0 else { return }
        product.lastLevelUpdate = now
        DispatchQueue.main.async { [weak self] in self?.orb.level = level; self?.smallOrb.level = level }
    }

    func cleanupProductUpgrades() {
        if let keyMonitor = product.keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let observer = product.screenObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = product.wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        product.reconnectWorkItem?.cancel()
    }
}
