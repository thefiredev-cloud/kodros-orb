import Cocoa
import CoreGraphics
import ScreenCaptureKit

extension AppDelegate {
    @objc func lookAtScreen() {
        captureAndAsk("Describe what is on this screen and help with what I am doing.")
    }

    func captureAndAsk(_ question: String) {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            updateStatus("screen access needs restart")
            if !product.screenPermissionWarningShown {
                product.screenPermissionWarningShown = true
                appendOutput("[screen] Screen access is not active. If Settings shows Kodros Orb on, quit and reopen Kodros Orb once.", color: kYellow)
            }
            return
        }
        product.screenPermissionWarningShown = false
        updateStatus("capturing…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await self.captureDisplayUnderPointer()
                DispatchQueue.main.async { self.sendScreenImage(image, question: question) }
            } catch {
                DispatchQueue.main.async {
                    self.updateStatus("ready")
                    self.appendOutput("[screen] Capture failed: \(error.localizedDescription)", color: kRed)
                }
            }
        }
    }

    func sendScreenImage(_ image: Data, question: String) {
        waitingForPi = true
        setOrbState(.thinking)
        updateStatus("looking…")
        appendOutput("you ◎ \(question)", color: kCyan)
        let attachment: [String: Any] = [
            "type": "image",
            "data": image.base64EncodedString(),
            "mimeType": "image/png",
        ]
        pi.prompt("""
        You are the screen-aware voice and text front end of Kodros Orb. Analyze the attached current display. \
        Answer the user's question directly. If action is requested, use your tools only after confirming \
        the visible target and preserve normal safety and approval gates.
        User question: \(question)
        """, images: [attachment]) { [weak self] result in
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    self?.waitingForPi = false
                    self?.setOrbState(.idle)
                    self?.appendOutput("[screen] \(error.localizedDescription)", color: kRed)
                }
            }
        }
    }

    // MARK: - Image paste

    // Cmd-V with an image on the pasteboard attaches it instead of pasting
    // text: a screenshot file, raw image data, or an image copied in an app.
    // The composer's text becomes the question; empty gets a sensible one.
    @discardableResult
    func pasteImageFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        var data: Data?
        if let urlString = pb.string(forType: .fileURL),
           let url = URL(string: urlString),
           ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(url.pathExtension.lowercased()) {
            data = imageDataForSending(contentsOf: url)
        }
        if data == nil, let png = pb.data(forType: .png) {
            data = png
        }
        if data == nil, let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let image = data else { return false }
        let question = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        inputField.stringValue = ""
        updateComposerState()
        sendScreenImage(image, question: question.isEmpty ? "Describe this image." : question)
        return true
    }

    // Downscales and re-encodes as PNG so huge pastes stay RPC-friendly.
    private func imageDataForSending(contentsOf url: URL, maxDimension: CGFloat = 1600) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width),
                                         pixelsHigh: Int(target.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func captureDisplayUnderPointer(maxDimension: Int = 2000) async throws -> Data {
        let target: (display: UInt32, panel: CGWindowID)? = await MainActor.run {
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
            guard let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (display, CGWindowID(panel.windowNumber))
        }
        guard let target else {
            throw PiClient.RPCError(message: "display under pointer not found")
        }

        let content = try await SCShareableContent.current
        let displayID = CGDirectDisplayID(target.display)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw PiClient.RPCError(message: "display is not shareable")
        }

        let excluded = content.windows.filter { $0.windowID == target.panel }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        let scale = min(1.0, Double(maxDimension) / Double(max(display.width, display.height)))
        configuration.width = Int(Double(display.width) * scale)
        configuration.height = Int(Double(display.height) * scale)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PiClient.RPCError(message: "PNG encoding failed")
        }
        return data
    }
}
