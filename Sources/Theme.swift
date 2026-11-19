import Cocoa

// MARK: - Kodros palette (kodros.ai)
// paper #F7F6F4 · graphite #33333A · white #FFFFFF.
// The brand mark is the white orb, so the UI accent is monochrome:
// pure white on dark, graphite on light. Green is retired from the UI.

private let paper = NSColor(calibratedRed: 0.969, green: 0.965, blue: 0.957, alpha: 1)      // #F7F6F4
private let graphite = NSColor(calibratedRed: 0.200, green: 0.200, blue: 0.227, alpha: 1)  // #33333A

private func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

let kBg       = adaptive(paper, graphite)
let kSurface  = adaptive(.white, NSColor(calibratedRed: 0.255, green: 0.255, blue: 0.286, alpha: 1))
let kBorder   = adaptive(graphite.withAlphaComponent(0.13), paper.withAlphaComponent(0.18))
let kText     = adaptive(graphite, paper)

// Accent is the white orb. kOnAccent is what sits on top of it.
let kAccent   = adaptive(graphite, .white)
let kOnAccent = adaptive(paper, graphite)

// Status colors — reserved for meaning, not decoration.
let kRed      = NSColor(calibratedRed: 0.973, green: 0.318, blue: 0.286, alpha: 1)
let kYellow   = NSColor(calibratedRed: 0.824, green: 0.600, blue: 0.133, alpha: 1)
let kDim      = adaptive(graphite.withAlphaComponent(0.72), paper.withAlphaComponent(0.72))

// Semantic aliases. Call sites read as intent; both are now the monochrome accent.
let kGreen    = kAccent
let kCyan     = kAccent

// Orb sphere gradient stops: bright core, accent mid, shaded rim for depth.
let kOrbCore  = NSColor.white
let kOrbEdge  = adaptive(NSColor(calibratedWhite: 0.08, alpha: 1),
                         NSColor(calibratedWhite: 0.38, alpha: 1))

// Typography — SF Pro and SF Mono at tuned sizes.
let kMonoFont      = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let kMonoFontSmall = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
let kUIFont        = NSFont.systemFont(ofSize: 13, weight: .semibold)
let kUIFontSmall   = NSFont.systemFont(ofSize: 11, weight: .regular)
let kChatFont      = NSFont.systemFont(ofSize: 13, weight: .regular)
let kTitleFont     = NSFont.systemFont(ofSize: 20, weight: .semibold)

// Transcript paragraph style: open line spacing so replies read easily.
let kChatParagraph: NSParagraphStyle = {
    let s = NSMutableParagraphStyle()
    s.lineSpacing = 3
    s.paragraphSpacing = 4
    return s
}()
