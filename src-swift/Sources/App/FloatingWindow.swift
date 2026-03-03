import AppKit
import MurmurCore

// MARK: - FloatingWindow

class FloatingWindow: NSWindow {
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        ignoresMouseEvents = true
        contentView = FloatingView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
    }

    func update(status: ASRStatus, text: String, levels: [Float]) {
        guard let view = contentView as? FloatingView else { return }
        view.status = status
        view.text = text
        view.targetLevels = levels
        view.needsDisplay = true

        if status == .idle {
            orderOut(nil)
        } else if !isVisible {
            orderFront(nil)
        }
    }

    func positionNearCursor(_ point: NSPoint) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        guard let screen = screen else { return }
        let sf = screen.visibleFrame
        let origin = NSPoint(
            x: sf.midX - frame.width / 2,
            y: sf.minY + 80
        )
        setFrameOrigin(origin)
    }
}

// MARK: - FloatingView

class FloatingView: NSView {
    var status: ASRStatus = .idle
    var text: String = ""
    var targetLevels: [Float] = Array(repeating: 0, count: 16)

    // Smoothed overall amplitude (single scalar)
    private var smoothAmp: CGFloat = 0.0
    private var phase: Double = 0
    private var animTimer: Timer?

    private let cornerRadius: CGFloat = 26
    private let pillHeight: CGFloat   = 48

    override var isFlipped: Bool { false }

    // MARK: - Animation lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startAnimation() } else { stopAnimation() }
    }

    private func startAnimation() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.animTick()
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func animTick() {
        guard status == .listening || status == .processing else { return }

        // RMS of incoming levels → single amplitude scalar
        let rms = sqrt(targetLevels.map { $0 * $0 }.reduce(0, +) / Float(max(1, targetLevels.count)))
        let target = CGFloat(max(0.08, rms * 3.2))
        let α: CGFloat = target > smoothAmp ? 0.30 : 0.05   // fast rise, slow fall
        smoothAmp += α * (target - smoothAmp)

        phase += 0.055   // ~3.3 rad/s → one cycle ≈ 1.9 s
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let pillRect = CGRect(
            x: 0, y: (bounds.height - pillHeight) / 2,
            width: bounds.width, height: pillHeight
        )

        // Background pill
        ctx.setFillColor(NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.93).cgColor)
        ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: cornerRadius,
                           cornerHeight: cornerRadius, transform: nil))
        ctx.fillPath()

        switch status {
        case .listening:
            drawSiriWave(in: pillRect, ctx: ctx, alpha: 1.0)
        case .processing:
            drawSiriWave(in: pillRect, ctx: ctx, alpha: 0.45)
        case .polishing:
            drawText(in: pillRect, alpha: 0.5)
        case .done:
            drawText(in: pillRect, alpha: 0.95)
        case .connecting:
            drawConnecting(in: pillRect, ctx: ctx)
        default:
            break
        }
    }

    // MARK: - Siri-style wave

    private func drawSiriWave(in rect: CGRect, ctx: CGContext, alpha: CGFloat) {
        let clipRect = rect.insetBy(dx: 0, dy: 2)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: clipRect, cornerWidth: cornerRadius,
                           cornerHeight: cornerRadius, transform: nil))
        ctx.clip()

        let path = wavePath(in: rect)

        // Wide diffuse glow — simulates light radiating from within the dark surface
        ctx.setStrokeColor(NSColor(red: 0.50, green: 0.75, blue: 1.0, alpha: 0.12 * alpha).cgColor)
        ctx.setLineWidth(10)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()

        // Mid layer
        ctx.setStrokeColor(NSColor(red: 0.65, green: 0.85, blue: 1.0, alpha: 0.28 * alpha).cgColor)
        ctx.setLineWidth(3)
        ctx.addPath(path)
        ctx.strokePath()

        // Core — semi-transparent blue-white, not solid white
        ctx.setStrokeColor(NSColor(red: 0.80, green: 0.92, blue: 1.0, alpha: 0.62 * alpha).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.restoreGState()
    }

    /// Smooth bezier path for the wave.
    /// Uses two overlapping sine harmonics so the shape feels organic rather than mechanically periodic.
    private func wavePath(in rect: CGRect) -> CGPath {
        let N      = 80
        let cy     = rect.midY
        let maxAmp = rect.height * 0.26 * smoothAmp

        var pts = [CGPoint]()
        pts.reserveCapacity(N + 1)

        for i in 0...N {
            let t  = Double(i) / Double(N)
            let x  = rect.minX + CGFloat(t) * rect.width

            // Primary wave + subtle second harmonic for organic feel
            let θ1 = t * .pi * 2.6 + phase
            let θ2 = t * .pi * 5.2 + phase * 1.7 + 1.0
            let y  = cy - maxAmp * (CGFloat(sin(θ1)) * 0.80 + CGFloat(sin(θ2)) * 0.20)

            pts.append(CGPoint(x: x, y: y))
        }

        // Cardinal-spline via midpoint quadratic bezier
        let path = CGMutablePath()
        path.move(to: pts[0])
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i+1].x) * 0.5,
                              y: (pts[i].y + pts[i+1].y) * 0.5)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    // MARK: - Other states

    private func drawText(in rect: CGRect, alpha: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor(white: 1.0, alpha: alpha)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz  = str.size()
        let maxW = rect.width - 24
        str.draw(in: CGRect(
            x: rect.midX - min(sz.width, maxW) / 2,
            y: rect.midY - sz.height / 2,
            width: min(sz.width, maxW),
            height: sz.height
        ))
    }

    private func drawConnecting(in rect: CGRect, ctx: CGContext) {
        let dotR: CGFloat    = 3.5
        let spacing: CGFloat = 11
        let startX = rect.midX - spacing
        ctx.setFillColor(NSColor(white: 1.0, alpha: 0.5).cgColor)
        for i in 0..<3 {
            ctx.fillEllipse(in: CGRect(
                x: startX + CGFloat(i) * spacing - dotR,
                y: rect.midY - dotR,
                width: dotR * 2, height: dotR * 2
            ))
        }
    }
}
