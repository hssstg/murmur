import AppKit
import MurmurCore

// MARK: - FloatingWindow

class FloatingWindow: NSPanel {
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }

    private let capsule: CapsuleView
    private var isShowing = false
    private let capsuleH: CGFloat = 56

    init() {
        capsule = CapsuleView(frame: NSRect(x: 0, y: 0, width: 76, height: 56))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 76, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        contentView = capsule
    }

    func update(status: ASRStatus, text: String, levels: [Float]) {
        capsule.update(status: status, text: text, levels: levels)

        if status == .idle {
            animateOut()
        } else {
            if !isShowing { animateIn() }
            resizeCapsule(for: text)
        }
    }

    func positionNearCursor(_ point: NSPoint) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        guard let screen = screen else { return }
        let sf = screen.visibleFrame
        setFrameOrigin(NSPoint(x: sf.midX - frame.width / 2, y: sf.minY + 80))
    }

    // MARK: - Private

    private func resizeCapsule(for text: String) {
        let targetW = capsule.desiredWidth(for: text)
        guard abs(frame.width - targetW) > 2 else { return }
        let midX = (screen ?? NSScreen.main)?.visibleFrame.midX ?? frame.midX
        let newFrame = NSRect(x: midX - targetW / 2, y: frame.minY, width: targetW, height: capsuleH)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    private func animateIn() {
        isShowing = true
        // Set correct size before showing
        let targetW = capsule.desiredWidth(for: capsule.currentText)
        let midX = (screen ?? NSScreen.main)?.visibleFrame.midX ?? frame.midX
        setFrame(NSRect(x: midX - targetW / 2, y: frame.minY, width: targetW, height: capsuleH), display: true)
        alphaValue = 1
        orderFront(nil)
    }

    private func animateOut() {
        guard isShowing else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            self.capsule.layer?.transform = CATransform3DMakeScale(0.85, 0.85, 1)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.capsule.layer?.transform = CATransform3DIdentity
            self?.alphaValue = 1
        })
    }
}

// MARK: - CapsuleView

private class CapsuleView: NSView {
    private let effectView = NSVisualEffectView()
    private let bars = WaveformBarsView()
    private let label = NSTextField(labelWithString: "")
    private(set) var currentText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .vibrantDark)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 28
        effectView.layer?.masksToBounds = true
        addSubview(effectView)

        addSubview(bars)

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.92)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(status: ASRStatus, text: String, levels: [Float]) {
        currentText = text
        label.stringValue = text
        label.isHidden = text.isEmpty
        bars.isHidden = !text.isEmpty
        bars.setLevels(levels, active: status == .listening)
    }

    func desiredWidth(for text: String) -> CGFloat {
        if text.isEmpty { return 76 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]
        let textW = min(560, max(160, ceil((text as NSString).size(withAttributes: attrs).width) + 4))
        return 16 + textW + 16
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        bars.frame = NSRect(x: 16, y: (bounds.height - 32) / 2, width: 44, height: 32)
        // When text is showing, it takes the full width; when hidden, waveform is centered
        let textX: CGFloat = 16
        let textW = max(0, bounds.width - textX - 16)
        label.frame = NSRect(x: textX, y: (bounds.height - 18) / 2, width: textW, height: 18)
    }
}

// MARK: - WaveformBarsView

private class WaveformBarsView: NSView {
    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private var smoothed: [CGFloat] = Array(repeating: 0.06, count: 5)
    private var amplitude: CGFloat = 0
    private var active = false
    private var animTimer: Timer?

    private let barW: CGFloat = 5
    private let barGap: CGFloat = 4.75  // (44 - 5×5) / 4
    private let barRadius: CGFloat = 2.5
    private let minBarH: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setLevels(_ levels: [Float], active: Bool) {
        self.active = active
        // levels[] are already normalized to [0,1] (rms * 20, clamped)
        // Use the latest value as current amplitude
        amplitude = CGFloat(levels.last ?? 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && animTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            animTimer = t
        } else if window == nil {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    private func tick() {
        for i in 0..<5 {
            let target: CGFloat
            if active {
                let jitter = CGFloat.random(in: -0.04...0.04)
                target = max(0.06, amplitude * Self.weights[i] * (1.0 + jitter))
            } else {
                target = 0.06
            }
            let rate: CGFloat = target > smoothed[i] ? 0.4 : 0.15
            smoothed[i] += rate * (target - smoothed[i])
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let totalW = 5 * barW + 4 * barGap
        let startX = (bounds.width - totalW) / 2

        ctx.setFillColor(NSColor(red: 0.82, green: 0.9, blue: 1.0, alpha: 0.88).cgColor)

        for i in 0..<5 {
            let x = startX + CGFloat(i) * (barW + barGap)
            let h = max(minBarH, bounds.height * smoothed[i])
            let y = (bounds.height - h) / 2
            let rect = CGRect(x: x, y: y, width: barW, height: h)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barRadius, cornerHeight: barRadius, transform: nil))
        }
        ctx.fillPath()
    }
}
