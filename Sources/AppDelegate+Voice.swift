import Cocoa
import AVFoundation
import Speech

extension AppDelegate {
    // MARK: - Voice session (preserved from v1)

    @objc func voiceToggleClicked() {
        toggleVoiceSession()
    }

    @objc func toggleVoiceMenu() {
        toggleVoiceSession()
    }

    func toggleVoiceSession() {
        if orb.state == .speaking || smallOrb.state == .speaking {
            interruptSpeech()
            return
        }
        if sessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        sessionActive = true
        stopping = false
        requestPermissions { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                if granted {
                    self.startListening()
                    self.voiceBtn?.contentTintColor = kGreen
                    self.appendOutput("[voice] Session started — speak now", color: kGreen)
                } else {
                    self.sessionActive = false
                    self.appendOutput("[voice] Microphone or speech permission denied. Tools → Privacy opens the right Settings pane.", color: kRed)
                }
            }
        }
    }

    func stopSession() {
        stopping = true
        sessionActive = false
        stopBargeMonitor()
        stopListening()
        synth.stopSpeaking(at: .immediate)
        pi.send(["type": "abort"]) { _ in }
        setOrbState(.idle)
        voiceBtn?.contentTintColor = kDim
        appendOutput("[voice] Session ended", color: kDim)
    }

    func requestPermissions(done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { micOK in
            SFSpeechRecognizer.requestAuthorization { status in
                done(micOK && status == .authorized)
            }
        }
    }

    // MARK: - Listening

    func startListening() {
        guard sessionActive, !synth.isSpeaking else { return }
        monitoringBarge = false
        setOrbState(.listening)
        transcript = ""
        lastTranscriptChange = Date()

        recogTask?.cancel()
        recogTask = nil
        recogRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if let r = recognizer, r.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }
        recogRequest = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recogRequest?.append(buffer)
            self?.updateLevel(buffer)
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                appendOutput("[voice] Audio engine failed.", color: kRed)
                return
            }
        }

        recogTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let t = result.bestTranscription.formattedString
                if t != self.transcript {
                    self.transcript = t
                    self.lastTranscriptChange = Date()
                    DispatchQueue.main.async {
                        self.updateStatus("listening · \(String(t.prefix(42)))")
                        self.statusLabel.toolTip = t
                    }
                }
            }
            if error != nil && self.sessionActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.sessionActive, !self.synth.isSpeaking else { return }
                    if self.orb.state == .listening || self.smallOrb.state == .listening {
                        self.startListening()
                    }
                }
            }
        }
    }

    func stopListening() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        recogRequest?.endAudio()
        recogRequest = nil
        recogTask?.cancel()
        recogTask = nil
    }

    func updateLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(max(n, 1)))
        let lvl = min(CGFloat(rms) * 6, 1)
        coalescedOrbLevel(lvl)
    }

    func checkEndpoint() {
        guard sessionActive else { return }
        let listening = orb.state == .listening || smallOrb.state == .listening
        guard listening, !transcript.isEmpty else { return }
        if Date().timeIntervalSince(lastTranscriptChange) > 1.3 {
            let said = transcript
            transcript = ""
            think(said)
        }
    }

    // MARK: - Thinking (voice)

    func think(_ text: String) {
        stopListening()
        setOrbState(.thinking)
        appendOutput("you 🎤 \(text)", color: kCyan)
        let lower = text.lowercased()
        if ["look at my screen", "look at this screen", "what is on my screen", "what's on my screen"].contains(where: lower.contains) {
            captureAndAsk(text)
            return
        }
        waitingForPi = true
        updateStatus("thinking…")

        pi.prompt("""
        You are the voice+text front end of pi running in a floating orb. \
        The user spoke this via voice mode. Reply in short, natural spoken language \
        (no markdown, no code blocks, no lists unless asked). \
        If the request needs real work (code, files, commands), do the work with your tools, \
        then summarize the outcome in one or two spoken sentences.
        Spoken input: \(text)
        """) { [weak self] result in
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    self?.waitingForPi = false
                    self?.setOrbState(.idle)
                    self?.updateStatus("ready")
                    self?.appendOutput("[voice] \(error.localizedDescription)", color: kRed)
                }
            }
        }
    }

    // MARK: - Speaking

    func speak(text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.speak(text: text) }
            return
        }
        setOrbState(.speaking)
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.pitchMultiplier = 1.0
        u.volume = 1.0
        let preferred = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe")
        let bestInstalled = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        u.voice = preferred ?? bestInstalled ?? AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let speaking = self.orb.state == .speaking || self.smallOrb.state == .speaking
            guard speaking else { return }
            self.startBargeMonitor()
        }
    }

    // MARK: - Barge-in

    func startBargeMonitor() {
        guard !monitoringBarge, sessionActive else { return }
        monitoringBarge = true
        bargeFrames = 0
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let lvl = min(CGFloat(rms) * 6, 1)
            self.coalescedOrbLevel(lvl)
            if rms > 0.045 { self.bargeFrames += 1 } else { self.bargeFrames = max(0, self.bargeFrames - 2) }
            if self.bargeFrames > 22 {
                self.bargeFrames = 0
                DispatchQueue.main.async { self.interruptSpeech() }
            }
        }
        if !engine.isRunning { try? engine.start() }
    }

    func stopBargeMonitor() {
        monitoringBarge = false
        bargeFrames = 0
    }

    func interruptSpeech() {
        let speaking = orb.state == .speaking || smallOrb.state == .speaking
        guard speaking else { return }
        stopBargeMonitor()
        synth.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resumeAfterSpeech()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resumeAfterSpeech()
    }

    func resumeAfterSpeech() {
        stopBargeMonitor()
        guard sessionActive, !stopping else { setOrbState(.idle); return }
        startListening()
    }

    func setOrbState(_ s: OrbView.State) {
        let status: String
        switch s {
        case .idle: status = "ready"
        case .listening: status = "listening…"
        case .thinking: status = "thinking…"
        case .speaking: status = "speaking…"
        }
        if Thread.isMainThread {
            orb.state = s
            smallOrb.state = s
            updateStatus(status)
        } else {
            DispatchQueue.main.async {
                self.orb.state = s
                self.smallOrb.state = s
                self.updateStatus(status)
            }
        }
    }

    // MARK: - Quit

    @objc func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        savePersistedTranscript()
        savePanelGeometry()
        removeSummonHotKey()
        stopListening()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        cleanupProductUpgrades()
        abortRunningCommands()
        pi.stop()
    }
}
