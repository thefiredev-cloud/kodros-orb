import Cocoa

extension AppDelegate {
    // MARK: - Input handling

    @objc func sendClicked() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        updateComposerState()
        handleInput(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let sel = commandSelector.description
        if sel == "insertNewline:" {
            sendClicked()
            return true
        }
        if sel == "insertTab:" { return completeSlashCommand() }
        if sel == "paste:", pasteImageFromPasteboard() { return true }
        // AppKit's default text bindings send Escape to complete:, which opened
        // the word-completion popup and left cancelOperation: unreachable. In a
        // command composer Escape always means dismiss.
        if sel == "cancelOperation:" || sel == "complete:" {
            collapsePanel()
            return true
        }
        if sel == "moveUp:" {
            historyUp()
            return true
        }
        if sel == "moveDown:" {
            historyDown()
            return true
        }
        return false
    }

    func historyUp() {
        guard !commandHistory.isEmpty else { return }
        if historyIndex < 0 { historyIndex = commandHistory.count - 1 }
        else if historyIndex > 0 { historyIndex -= 1 }
        inputField.stringValue = commandHistory[historyIndex]
        updateComposerState()
    }

    func historyDown() {
        guard historyIndex >= 0 else { return }
        historyIndex += 1
        if historyIndex >= commandHistory.count {
            historyIndex = -1
            inputField.stringValue = ""
        } else {
            inputField.stringValue = commandHistory[historyIndex]
        }
        updateComposerState()
    }

    // MARK: - Command parsing

    func handleInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        commandHistory.append(text)
        historyIndex = -1
        UserDefaults.standard.set(Array(commandHistory.suffix(50)), forKey: "command.history")

        if text == "/help" {
            showHelp()
        } else if text == "/clear" {
            clearOutputAction()
        } else if text == "/voice" {
            toggleVoiceSession()
        } else if text == "/collapse" || text == "/close" {
            collapsePanel()
        } else if text == "/expand" || text == "/open" {
            expandPanel()
        } else if text == "/look" || text.hasPrefix("/look ") {
            let question = text.count > 5 ? String(text.dropFirst(6)) : "Describe what is on this screen and help with what I am doing."
            captureAndAsk(question)
        } else if text.hasPrefix("! ") || text.hasPrefix("/bash ") {
            let cmd = text.hasPrefix("! ") ? String(text.dropFirst(2)) : String(text.dropFirst(6))
            appendOutput("you $ \(cmd)", color: kCyan)
            runLocalCommand(cmd)
        } else if text.hasPrefix("@ ") || text.hasPrefix("/ssh ") {
            let cmd = text.hasPrefix("@ ") ? String(text.dropFirst(2)) : String(text.dropFirst(5))
            appendOutput("you @ remote-host $ \(cmd)", color: kCyan)
            runSSHCommand(cmd)
        } else if text.hasPrefix("/vault") {
            let args = text.count > 6 ? String(text.dropFirst(7)) : ""
            appendOutput("you /vault \(args)", color: kCyan)
            runVaultCommand(args)
        } else if text.hasPrefix("/graphify ") || text.hasPrefix("/graph ") {
            let q = text.hasPrefix("/graphify ") ? String(text.dropFirst(10)) : String(text.dropFirst(7))
            appendOutput("you /graphify \(q)", color: kCyan)
            runRecallQuery(q)
        } else if text.hasPrefix("/recall ") {
            let q = String(text.dropFirst(8))
            appendOutput("you /recall \(q)", color: kCyan)
            runRecallQuery(q)
        } else if text.hasPrefix("/model ") {
            let m = String(text.dropFirst(7))
            appendOutput("you /model \(m)", color: kCyan)
            switchModel(m)
        } else if text.hasPrefix("/abort") {
            appendOutput("[system] Aborting…", color: kYellow)
            pi.send(["type": "abort"]) { _ in }
            abortRunningCommands()
        } else {
            // Send as pi prompt
            product.lastPrompt = text
            appendOutput("you › \(text)", color: kCyan)
            sendPiPrompt(text)
        }
    }

    // MARK: - Command execution

    func runLocalCommand(_ cmd: String) {
        runProcess(executable: "/bin/bash", arguments: ["-c", cmd], label: cmd)
    }

    func runSSHCommand(_ cmd: String) {
        runProcess(executable: "/usr/bin/ssh", arguments: ["remote-host", cmd], label: "ssh remote-host: \(cmd)")
    }

    func runVaultCommand(_ args: String) {
        let parts = args.split(separator: " ", maxSplits: 2).map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bin = "\(home)/.meshvault/tooling/bin/meshvault-skill"

        if parts.isEmpty || parts[0].isEmpty {
            appendOutput("  Usage: /vault search <query>", color: kDim)
            appendOutput("         /vault fetch <id>", color: kDim)
            appendOutput("         /vault read <id> <file>", color: kDim)
            return
        }

        let sub = parts[0].lowercased()
        var cmdArgs: [String] = []
        switch sub {
        case "search":
            cmdArgs = ["search"] + parts.dropFirst().map { $0 }
            if cmdArgs.count < 2 {
                appendOutput("  Usage: /vault search <query>", color: kDim)
                return
            }
        case "fetch":
            cmdArgs = ["fetch"] + parts.dropFirst().map { $0 }
            if cmdArgs.count < 2 {
                appendOutput("  Usage: /vault fetch <id>", color: kDim)
                return
            }
        case "read":
            cmdArgs = ["read"] + parts.dropFirst().map { $0 }
            if cmdArgs.count < 3 {
                appendOutput("  Usage: /vault read <id> <file>", color: kDim)
                return
            }
        default:
            cmdArgs = parts
        }
        runProcess(executable: bin, arguments: cmdArgs, label: "vault \(args)")
    }

    func runRecallQuery(_ q: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bin = "\(home)/.local/bin/graphify-recall"
        runProcess(executable: bin, arguments: ["recall", q, "--budget", "1200"], label: "recall: \(q)")
    }

    func runProcess(executable: String, arguments: [String], label: String) {
        guard !isRunningCommand else {
            appendOutput("[system] A command is already running. Use /abort to stop it.", color: kYellow)
            return
        }
        isRunningCommand = true
        updateStatus("running…")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:\(home)/.meshvault/tooling/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = home
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendOutput(str, color: kGreen, newline: false, font: kMonoFont) }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendOutput(str, color: kRed, newline: false, font: kMonoFont) }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.appendOutput("[exit \(p.terminationStatus)]", color: kDim)
                self?.isRunningCommand = false
                self?.activeProcesses.removeAll { $0 === p }
                self?.updateStatus("ready")
            }
        }

        do {
            try proc.run()
            activeProcesses.append(proc)
        } catch {
            appendOutput("[error] Failed to run: \(error.localizedDescription)", color: kRed)
            isRunningCommand = false
            updateStatus("ready")
        }
    }

    func abortRunningCommands() {
        for p in activeProcesses { p.terminate() }
        activeProcesses.removeAll()
        isRunningCommand = false
        updateStatus("ready")
    }

    // MARK: - Pi prompt

    func sendPiPrompt(_ text: String) {
        waitingForPi = true
        setOrbState(.thinking)
        pi.prompt("""
        You are the text and voice front end of Pi running inside a floating desktop orb. \
        Reply in clear, natural English. If the request needs real work, use your tools and \
        verification gates, then report the observed result. Keep simple answers concise.
        User message: \(text)
        """) { [weak self] result in
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    self?.waitingForPi = false
                    self?.setOrbState(.idle)
                    self?.appendOutput("[Kodros Orb] \(error.localizedDescription)", color: kRed)
                }
            }
        }
    }

    func handlePiEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if type == "extension_error" {
            let message = event["error"] as? String ?? "extension error"
            DispatchQueue.main.async { self.appendOutput("[Kodros Orb] \(message)", color: kRed) }
        } else if type == "message_update" {
            guard let ame = event["assistantMessageEvent"] as? [String: Any],
                  ame["type"] as? String == "text_delta",
                  let delta = ame["delta"] as? String, !delta.isEmpty else { return }
            DispatchQueue.main.async { self.appendStreamDelta(delta) }
        } else if type == "tool_execution_start" {
            let tool = event["toolName"] as? String ?? "tool"
            DispatchQueue.main.async { self.updateStatus("running \(tool)…") }
        } else if type == "agent_settled" {
            pi.lastAssistantText { [weak self] text in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.waitingForPi = false
                    self.setOrbState(.idle)
                    let response = text ?? "Done."
                    self.product.lastResponse = response
                    if self.product.streamTextStart != nil {
                        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.replaceStreamWithFinal(text, color: kText)
                        } else {
                            self.clearStreamMarker(appendNewline: true)
                        }
                    } else {
                        self.appendRichOutput(response, color: kText)
                    }
                    self.updateStatus("ready")
                    self.savePersistedTranscript()
                    // Also speak if voice session active
                    if self.sessionActive {
                        let spoken = speakable(response)
                        self.speak(text: spoken.isEmpty ? "Done." : spoken)
                    }
                }
            }
        }
    }

    // MARK: - Model switching

    func switchModel(_ spec: String) {
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            pi.send(["type": "set_model", "provider": parts[0], "modelId": parts[1]], timeout: 10) { [weak self] r in
                DispatchQueue.main.async {
                    if case .success = r {
                        self?.pi.send(["type": "set_thinking_level", "level": "high"], timeout: 10) { _ in }
                        self?.appendOutput("[system] Model set to \(spec) · high reasoning", color: kGreen)
                    } else {
                        self?.appendOutput("[error] Failed to set model", color: kRed)
                    }
                    self?.updateModelLabel()
                }
            }
        } else {
            appendOutput("  Usage: /model provider/modelId", color: kDim)
        }
    }

    @objc func useDefaultBrain() {
        guard let d = defaultModel else { return }
        setBrain(provider: d.provider, model: d.id)
    }

    @objc func useQwenBrain() {
        setBrain(provider: "qwen-token-plan", model: "qwen3.8-max-preview")
    }

    func setBrain(provider: String, model: String) {
        pi.send(["type": "set_model", "provider": provider, "modelId": model], timeout: 10) { [weak self] result in
            if case .success = result {
                self?.pi.send(["type": "set_thinking_level", "level": "high"], timeout: 10) { _ in }
            }
            DispatchQueue.main.async { self?.updateModelLabel() }
        }
    }

    // MARK: - Output display

    func appendOutput(_ text: String, color: NSColor, prefix: String = "", newline: Bool = true,
                      font: NSFont = kChatFont) {
        guard let tv = outputTV else { return }
        welcomeView?.isHidden = true
        // Only follow the tail when the user is already at the bottom.
        let nearBottom = outputScroll.contentView.documentVisibleRect.maxY >= tv.frame.height - 48
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: kChatParagraph,
        ]
        let str = timestampPrefix() + prefix + text + (newline ? "\n" : "")
        let attr = NSAttributedString(string: str, attributes: attrs)
        tv.textStorage?.append(attr)
        if nearBottom { tv.scrollToEndOfDocument(nil) }
    }

    // Mechanical only. Startup calls this through showWelcome() before the
    // saved transcript is read back, so dropping the file here would erase
    // the conversation on every launch. Discarding is clearOutputAction().
    func clearOutput() {
        snapshotConversationBeforeClear()
        clearStreamMarker(appendNewline: false)
        outputTV?.string = ""
    }

    // The one route that means "the user threw the conversation away".
    @objc func clearOutputAction() {
        showWelcome()
        deletePersistedTranscript()
    }

    func showWelcome() {
        clearOutput()
        welcomeView?.isHidden = !expanded
    }

    func showHelp() {
        let help = """

        ── Anywhere ──────────────────────────────
          \(AppDelegate.summonHotKeyLabel)            Summon Kodros Orb from any app
          Esc                Dismiss back to the orb

        ── Commands ──────────────────────────────
          /help              Show this help
          /clear             Clear output
          /voice             Toggle voice mode
          /look [question]   Share this display with Kodros Orb
          /collapse          Collapse to orb
          /abort             Abort running command

        ── CLI Shortcuts ─────────────────────────
          ! <cmd>            Run local bash command (or /bash)
          @ <cmd>            Run command on remote-host via SSH (or /ssh)

        ── Vault (on your Kodros server) ─────────
          /vault search <q>  Search skill library
          /vault fetch <id>  Fetch skill body · /vault read <id> <f>

        ── Knowledge Graph ───────────────────────
          /graphify <q>      Query graph on remote-host
          /recall <q>        Local graphify recall

        ── Kodros Orb ──────────────────────────────
          <text>             Send a prompt to Kodros Orb
          /model p/m         Switch model with high reasoning

        ── Voice ─────────────────────────────────
          Click orb          Open the chat panel
          Follow Clicks      Orb stays near your last click
          Speak while TTS    Barge-in (interrupt)

        ── Keyboard ──────────────────────────────
          Enter              Send message
          Command-Return     Send message
          Command-V          Paste text, or attach an image
          Escape             Collapse panel
          ↑ / ↓              Command history
          Command-L          Focus composer
          Command-K          Open Tools
          Command-F          Find in conversation
          Command-.          Abort current action
          Command-Shift-C    Copy latest response
          Command-Shift-R    Retry latest prompt
          Command-Shift-P    Pin or unpin panel
          Command +/-/0      Change conversation text size

        ── Panel ─────────────────────────────────
          Drag corner to resize · welcome chips start Screen, Vault, Terminal

        """
        appendOutput(help, color: kAccent, newline: false, font: kMonoFont)
    }

    // MARK: - Quick action buttons

    func prefillComposer(_ text: String) {
        inputField.stringValue = text
        updateComposerState()
        panel.makeKey()
        inputField.window?.makeFirstResponder(inputField)
    }

    @objc func qVault() { prefillComposer("/vault search ") }
    @objc func qBash() { prefillComposer("! ") }
    @objc func qSSH() { prefillComposer("@ ") }
    @objc func qGraph() { prefillComposer("/graphify ") }
    @objc func qLook() { lookAtScreen() }

    // MARK: - Runtime log noise control

    func appendRuntimeLog(_ message: String) {
        let significant = message.range(of: "error|fail|exceed|denied|disconnect|invalid",
                                        options: [.regularExpression, .caseInsensitive]) != nil
        guard significant else { return }
        let now = Date()
        if message == product.lastRuntimeLog, now.timeIntervalSince(product.lastRuntimeLogDate) < 60 {
            product.runtimeLogRepeat += 1
            product.lastRuntimeLogDate = now
            return
        }
        if product.runtimeLogRepeat > 0 {
            appendOutput("[Kodros Orb] (last message repeated ×\(product.runtimeLogRepeat))", color: kDim)
        }
        product.runtimeLogRepeat = 0
        product.lastRuntimeLog = message
        product.lastRuntimeLogDate = now
        appendOutput("[Kodros Orb] \(message)", color: kYellow)
    }

    // MARK: - Status updates

    func updateStatus(_ text: String) {
        statusLabel?.stringValue = "Kodros Orb · \(text)"
        updateProductActivity(for: text)
    }

    func updateConnectionStatus() {
        let connected = pi.isRunning
        connDot?.layer?.backgroundColor = (connected ? kGreen : kRed).cgColor
        connLabel?.stringValue = connected ? "Kodros connected" : "Kodros offline"
        updateAccessibleConnection(connected)
    }

    func updateModelLabel() {
        pi.send(["type": "get_state"], timeout: 5) { [weak self] r in
            if case .success(let o) = r,
               let d = o["data"] as? [String: Any],
               let m = d["model"] as? [String: Any] {
                let name = (m["id"] as? String) ?? "unknown"
                DispatchQueue.main.async {
                    self?.modelLabel?.stringValue = name
                    self?.modelLabel?.toolTip = "Copy \(name)"
                    self?.modelLabel?.setAccessibilityValue(name)
                }
            }
        }
    }

}
