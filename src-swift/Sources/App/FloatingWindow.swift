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
        view.levels = levels
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
    var levels: [Float] = Array(repeating: 0, count: 16)

    private let cornerRadius: CGFloat = 26
    private let pillHeight: CGFloat   = 48
    private let barWidth: CGFloat     = 3
    private let barSpacing: CGFloat   = 2.5

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Pill background
        let pillRect = CGRect(
            x: 0,
            y: (bounds.height - pillHeight) / 2,
            width: bounds.width,
            height: pillHeight
        )
        let bgColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.93)
        ctx.setFillColor(bgColor.cgColor)
        let path = CGPath(roundedRect: pillRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        switch status {
        case .listening:
            drawWaveform(in: pillRect, ctx: ctx, alpha: 0.9)
        case .processing:
            drawWaveform(in: pillRect, ctx: ctx, alpha: 0.4)
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

    private func drawWaveform(in rect: CGRect, ctx: CGContext, alpha: CGFloat) {
        let n = levels.count
        let totalWidth = CGFloat(n) * barWidth + CGFloat(n - 1) * barSpacing
        var x = rect.midX - totalWidth / 2
        let centerY = rect.midY

        for level in levels {
            let barH = max(4, CGFloat(level) * rect.height * 0.72)
            ctx.setFillColor(NSColor(red: 0.30, green: 0.72, blue: 1.0, alpha: alpha).cgColor)
            let barRect = CGRect(x: x, y: centerY - barH / 2, width: barWidth, height: barH)
            let bar = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            ctx.addPath(bar)
            ctx.fillPath()
            x += barWidth + barSpacing
        }
    }

    private func drawText(in rect: CGRect, alpha: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor(white: 1.0, alpha: alpha)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        // Clamp text width
        let maxW = rect.width - 24
        let drawRect = CGRect(
            x: rect.midX - min(sz.width, maxW) / 2,
            y: rect.midY - sz.height / 2,
            width: min(sz.width, maxW),
            height: sz.height
        )
        str.draw(in: drawRect)
    }

    private func drawConnecting(in rect: CGRect, ctx: CGContext) {
        let dotR: CGFloat = 3.5
        let spacing: CGFloat = 11
        let startX = rect.midX - spacing
        ctx.setFillColor(NSColor(white: 1.0, alpha: 0.5).cgColor)
        for i in 0..<3 {
            let dot = CGRect(
                x: startX + CGFloat(i) * spacing - dotR,
                y: rect.midY - dotR, width: dotR * 2, height: dotR * 2
            )
            ctx.fillEllipse(in: dot)
        }
    }
}
