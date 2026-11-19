import Cocoa

// MARK: - Transcript rendering (assistant replies)

extension AppDelegate {

    // True when the conversation is pinned to the bottom, so appends may
    // auto-scroll. When the user scrolls up to read, position is preserved.
    func conversationPinnedToBottom() -> Bool {
        guard let tv = outputTV, let scroll = tv.enclosingScrollView else { return true }
        let contentH = scroll.documentView?.frame.height ?? 0
        return scroll.contentView.bounds.maxY >= contentH - 48
    }

    // Renders the markdown subset Pi emits: fenced code blocks, **bold**,
    // `code`, # headings, and clickable URLs. Sizes follow product.textSize.
    func appendRichOutput(_ text: String, color: NSColor) {
        guard let tv = outputTV else { return }
        welcomeView?.isHidden = true
        let pinned = conversationPinnedToBottom()
        let size = CGFloat(product.textSize)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: timestampPrefix() + "Kodros Orb › ", attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: kDim,
            .paragraphStyle: kChatParagraph,
        ]))
        out.append(renderMarkdownBody(text, color: color))
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .paragraphStyle: kChatParagraph,
        ]))
        tv.textStorage?.append(out)
        if pinned { tv.scrollToEndOfDocument(nil) }
    }

    // Body-only render, shared by appendRichOutput and stream replacement.
    func renderMarkdownBody(_ text: String, color: NSColor) -> NSAttributedString {
        let size = CGFloat(product.textSize)
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: kChatParagraph,
        ]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: kChatParagraph,
        ]
        let mono: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(10, size - 1), weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: kChatParagraph,
        ]
        let out = NSMutableAttributedString()
        // Split fenced code blocks first; prose segments get inline styling.
        let fence = try? NSRegularExpression(pattern: "```\\w*\\n?([\\s\\S]*?)```")
        let ns = text as NSString
        var cursor = 0
        var segments: [(String, Bool)] = [] // (text, isCode)
        for m in fence?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if m.range.location > cursor {
                segments.append((ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), false))
            }
            segments.append((ns.substring(with: m.range(at: 1)), true))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { segments.append((ns.substring(from: cursor), false)) }

        for (segment, isCode) in segments {
            if isCode {
                let code = segment.trimmingCharacters(in: .newlines)
                if !code.isEmpty {
                    var codeAttrs = mono
                    codeAttrs[.backgroundColor] = kText.withAlphaComponent(0.07)
                    out.append(NSAttributedString(string: "\n" + code + "\n", attributes: codeAttrs))
                }
            } else {
                appendInline(segment, to: out, plain: plain, bold: bold, mono: mono)
            }
        }
        return out
    }

    // Inline styling for one prose segment: headings, **bold**, *italic*,
    // `code`, URLs.
    private func appendInline(_ raw: String, to out: NSMutableAttributedString,
                              plain: [NSAttributedString.Key: Any],
                              bold: [NSAttributedString.Key: Any],
                              mono: [NSAttributedString.Key: Any]) {
        // Heading markers become plain lines (weight comes from ** if present).
        let body = raw.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        let ns = body as NSString
        var italic = plain
        if let font = plain[.font] as? NSFont {
            italic[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let pattern = "\\*\\*(.+?)\\*\\*|\\*([^*\\n]+)\\*|`([^`\\n]+)`|(https?://[^\\s)\\]]+)|((?m)^\\s*-{3,}\\s*$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            out.append(NSAttributedString(string: body, attributes: plain))
            return
        }
        var cursor = 0
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), attributes: plain))
            }
            if m.range(at: 1).location != NSNotFound {
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 1)), attributes: bold))
            } else if m.range(at: 2).location != NSNotFound {
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 2)), attributes: italic))
            } else if m.range(at: 3).location != NSNotFound {
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 3)), attributes: mono))
            } else if m.range(at: 5).location != NSNotFound {
                var ruleAttrs = plain
                ruleAttrs[.foregroundColor] = kDim
                out.append(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}", attributes: ruleAttrs))
            } else {
                let urlString = ns.substring(with: m.range(at: 4))
                var linkAttrs = plain
                linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                linkAttrs[.foregroundColor] = kAccent
                if let url = URL(string: urlString) { linkAttrs[.link] = url }
                out.append(NSAttributedString(string: urlString, attributes: linkAttrs))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: cursor), attributes: plain))
        }
    }

    // MARK: - Live streaming

    // Appends one streamed text delta. The first delta opens the reply with
    // the dim prefix and marks where final replacement starts.
    func appendStreamDelta(_ delta: String) {
        guard let tv = outputTV else { return }
        welcomeView?.isHidden = true
        let pinned = conversationPinnedToBottom()
        let size = CGFloat(product.textSize)
        if product.streamTextStart == nil {
            tv.textStorage?.append(NSAttributedString(string: timestampPrefix() + "Kodros Orb › ", attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: kDim,
                .paragraphStyle: kChatParagraph,
            ]))
            product.streamTextStart = tv.textStorage?.length
        }
        tv.textStorage?.append(NSAttributedString(string: delta, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: kText,
            .paragraphStyle: kChatParagraph,
        ]))
        if pinned { tv.scrollToEndOfDocument(nil) }
    }

    // Swaps the plain streamed text for the fully rendered reply.
    func replaceStreamWithFinal(_ response: String, color: NSColor) {
        guard let tv = outputTV, let start = product.streamTextStart,
              let storage = tv.textStorage, start <= storage.length else {
            appendRichOutput(response, color: color)
            return
        }
        product.streamTextStart = nil
        let pinned = conversationPinnedToBottom()
        storage.deleteCharacters(in: NSRange(location: start, length: storage.length - start))
        storage.append(renderMarkdownBody(response, color: color))
        storage.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(product.textSize)),
        ]))
        if pinned { tv.scrollToEndOfDocument(nil) }
    }

    // Aborts and clears drop the stream marker without touching text.
    func clearStreamMarker(appendNewline: Bool) {
        product.streamTextStart = nil
        if appendNewline {
            outputTV?.textStorage?.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(product.textSize)),
            ]))
        }
    }
}
