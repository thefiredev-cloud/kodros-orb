import Cocoa


// MARK: - Shared orb animation

final class OrbAnimator {
    static let shared = OrbAnimator()
    private let views = NSHashTable<OrbView>.weakObjects()
    private let timer: Timer

    private init() {
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            for view in OrbAnimator.shared.views.allObjects where !view.isHiddenOrHasHiddenAncestor {
                if view.window?.occlusionState.contains(.visible) != false { view.tick() }
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .default)
    }

    func register(_ view: OrbView) { views.add(view) }
    func unregister(_ view: OrbView) { views.remove(view) }
}

// MARK: - Orb view (enhanced with orbit ring + particles)

final class OrbView: NSView {
    enum State { case idle, listening, thinking, speaking }
    var state: State = .idle { didSet { applyStateAppearance() } }
    var level: CGFloat = 0

    private let glow = CALayer()
    private let core = CAGradientLayer()
    private let highlight = CAGradientLayer()
    private let orbitRing = CAShapeLayer()
    private var orbitDots: [CALayer] = []
    private var phase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        glow.backgroundColor = kAccent.withAlphaComponent(0.5).cgColor
        glow.shadowColor = kAccent.cgColor
        glow.shadowRadius = 22
        glow.shadowOpacity = 0.7
        glow.shadowOffset = .zero
        layer?.addSublayer(glow)

        // Lit-pearl shading: bright core falling off to a shaded rim.
        let mid = kAccent.blended(withFraction: 0.3, of: kOrbEdge) ?? kAccent
        core.type = .radial
        core.colors = [
            kOrbCore.cgColor,
            mid.cgColor,
            kOrbEdge.cgColor,
        ]
        core.locations = [0, 0.55, 1]
        core.startPoint = CGPoint(x: 0.40, y: 0.60)
        core.endPoint = CGPoint(x: 1, y: 0)
        core.masksToBounds = true
        layer?.addSublayer(core)

        highlight.type = .radial
        highlight.colors = [
            NSColor.white.withAlphaComponent(0.95).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        highlight.locations = [0, 1]
        highlight.startPoint = CGPoint(x: 0.5, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 1)
        highlight.masksToBounds = true
        layer?.addSublayer(highlight)

        // Orbit ring
        orbitRing.fillColor = NSColor.clear.cgColor
        orbitRing.strokeColor = kAccent.withAlphaComponent(0.35).cgColor
        orbitRing.lineWidth = 1.0
        layer?.addSublayer(orbitRing)

        // Orbiting particles
        for _ in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = kAccent.withAlphaComponent(0.9).cgColor
            dot.cornerRadius = 1.25
            dot.bounds = CGRect(x: 0, y: 0, width: 2.5, height: 2.5)
            dot.shadowColor = kAccent.cgColor
            dot.shadowRadius = 2.5
            dot.shadowOpacity = 0.7
            layer?.addSublayer(dot)
            orbitDots.append(dot)
        }

        OrbAnimator.shared.register(self)
        applyStateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyStateAppearance() {
        let color: NSColor
        switch state {
        case .idle: color = kAccent
        case .listening: color = kGreen
        case .thinking: color = kYellow
        case .speaking: color = kCyan
        }
        glow.backgroundColor = color.withAlphaComponent(0.5).cgColor
        glow.shadowColor = color.cgColor
        orbitRing.strokeColor = color.withAlphaComponent(0.4).cgColor
        orbitDots.forEach {
            $0.backgroundColor = color.withAlphaComponent(0.9).cgColor
            $0.shadowColor = color.cgColor
        }
    }

    override func layout() {
        super.layout()
        // Small orbs (header, hero) skip the ring and particles — at that
        // size they read as noise.
        let compact = min(bounds.width, bounds.height) < 44
        orbitRing.isHidden = compact
        orbitDots.forEach { $0.isHidden = compact }
        let d = min(bounds.width, bounds.height) * 0.55
        let rect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = rect
        glow.cornerRadius = d / 2
        core.frame = rect
        core.cornerRadius = d / 2
        // Specular highlight rides the upper-left of the sphere.
        let hd = d * 0.42
        highlight.frame = CGRect(x: rect.minX + d * 0.15, y: rect.midY + d * 0.06, width: hd, height: hd)
        highlight.cornerRadius = hd / 2
        // Orbit ring: slightly larger than orb
        let ringD = d * 1.2
        let ringRect = CGRect(x: (bounds.width - ringD) / 2, y: (bounds.height - ringD) / 2, width: ringD, height: ringD)
        orbitRing.path = CGPath(ellipseIn: ringRect, transform: nil)
        orbitRing.frame = bounds
        CATransaction.commit()
    }

    fileprivate func tick() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion { phase += 1.0 / 60.0 }
        var scale: CGFloat = 1.0
        var glowBoost: Float = 0.85
        var ringSpeed: CGFloat = 0.3
        var ringOpacity: CGFloat = 0.35
        let compact = min(bounds.width, bounds.height) < 44

        switch state {
        case .idle:
            scale = 1.0 + 0.008 * sin(phase * 1.2)
            glowBoost = 0.45
            ringSpeed = 0.2
        case .listening:
            scale = 1.0 + 0.02 * sin(phase * 2.0) + level * 0.12
            glowBoost = 0.65 + Float(level) * 0.2
            ringSpeed = 0.6
            ringOpacity = 0.45
        case .thinking:
            scale = 1.0 + 0.035 * sin(phase * 4.0)
            glowBoost = 0.75
            ringSpeed = 1.25
            ringOpacity = 0.6
        case .speaking:
            scale = 1.0 + 0.025 * sin(phase * 6.0) + level * 0.10
            glowBoost = 0.7 + Float(level) * 0.1
            ringSpeed = 1.0
            ringOpacity = 0.45
        }
        if reduceMotion { scale = 1; ringSpeed = 0 }

        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 30.0)
        let t = CGAffineTransform(scaleX: scale, y: scale)
        core.setAffineTransform(t)
        glow.setAffineTransform(t)
        glow.shadowOpacity = glowBoost
        highlight.setAffineTransform(t)

        // Rotate orbit ring
        orbitRing.setAffineTransform(CGAffineTransform(rotationAngle: phase * ringSpeed))
        orbitRing.opacity = compact ? 0 : Float(ringOpacity)

        // Orbit particles
        let orbRadius = min(bounds.width, bounds.height) * 0.62 * 0.625 * scale
        for (i, dot) in orbitDots.enumerated() {
            guard !compact else { break }
            let speed = ringSpeed * (0.7 + CGFloat(i) * 0.25)
            let offset = CGFloat(i) * (.pi / 2.0)
            let angle = phase * speed + offset
            let cx = bounds.midX + cos(angle) * orbRadius
            let cy = bounds.midY + sin(angle) * orbRadius
            dot.position = CGPoint(x: cx, y: cy)
            dot.opacity = Float(0.5 + 0.5 * sin(phase * 2 + CGFloat(i)))
        }

        CATransaction.commit()
    }

    deinit { OrbAnimator.shared.unregister(self) }
}
