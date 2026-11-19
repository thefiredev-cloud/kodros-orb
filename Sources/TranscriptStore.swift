import Cocoa

// MARK: - Transcript persistence

// The conversation survives relaunches. Saved as RTFD so formatting and
// links round-trip; stored beside other app data, never off-device.
extension AppDelegate {
    private var transcriptURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mesh Orb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript.rtfd")
    }

    func savePersistedTranscript() {
        guard let tv = outputTV else { return }
        let attr = tv.attributedString()
        if attr.length == 0 {
            try? FileManager.default.removeItem(at: transcriptURL)
            return
        }
        // Dynamic colors must become static sRGB before archiving — the
        // RTF writer resolves against NSAppearance.current, not the drawing
        // appearance, and bakes the wrong variant. Resolve by hand.
        let flat = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: flat.length)
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineColor] {
                flat.enumerateAttribute(key, in: full) { value, range, _ in
                    guard let color = value as? NSColor,
                          let rgb = color.usingColorSpace(.sRGB) else { return }
                    flat.addAttribute(key, value: rgb, range: range)
                }
            }
        }
        guard let data = try? flat.data(from: full,
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else { return }
        try? data.write(to: transcriptURL, options: .atomic)
    }

    func restorePersistedTranscript() {
        guard let tv = outputTV,
              let data = try? Data(contentsOf: transcriptURL),
              let attr = try? NSAttributedString(data: data,
                                                 options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                 documentAttributes: nil),
              attr.length > 0 else { return }
        tv.textStorage?.setAttributedString(attr)
        welcomeView?.isHidden = true
        scrollConversationBottom()
    }

    // User-initiated clear also drops the saved copy.
    func deletePersistedTranscript() {
        try? FileManager.default.removeItem(at: transcriptURL)
    }
}
