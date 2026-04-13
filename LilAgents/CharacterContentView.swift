import AppKit

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class NonKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// `NSWindow` may wrap `contentView` in views that still accept hits when the sprite returns nil.
/// This root never claims hits itself — only `spriteView` can — so transparent areas click through.
final class CharacterWindowHostView: NSView {
    let spriteView: CharacterContentView

    init(spriteView: CharacterContentView, frame frameRect: NSRect) {
        self.spriteView = spriteView
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        addSubview(spriteView)
        spriteView.frame = bounds
        spriteView.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return spriteView.hitTest(p)
    }
}

class CharacterContentView: NSView {
    weak var character: WalkerCharacter?

    override var isOpaque: Bool { false }

    /// Portrait video: transparent “sky” above the sprite — pass through without sampling.
    private var interactiveRegionMaxY: CGFloat {
        bounds.height * 0.48
    }

    /// Bottom strip (feet / dock overlap): pass through so Dock icons stay clickable.
    private var dockPassThroughMaxY: CGFloat {
        bounds.height * 0.09
    }

    /// Transparent letterboxing left/right of the character — pass through to apps behind.
    private func isOutsideHorizontalSpriteBand(_ localPoint: NSPoint) -> Bool {
        let w = bounds.width
        guard w > 1 else { return false }
        let nx = localPoint.x / w
        return nx < 0.24 || nx > 0.76
    }

    /// CGWindowListCreateImage uses global display coords with Y measured from the top of
    /// the virtual desktop (not “primary height − y” on a single screen).
    private static func cgCaptureRectForScreenPoint(_ screenPoint: NSPoint) -> CGRect {
        let union = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let cgY = union.maxY - screenPoint.y
        return CGRect(x: screenPoint.x - 0.5, y: cgY - 0.5, width: 1, height: 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // NSView origin is bottom-left: small Y = near Dock / feet, large Y = empty sky.
        if localPoint.y > interactiveRegionMaxY {
            return nil
        }
        if localPoint.y < dockPassThroughMaxY {
            return nil
        }

        if isOutsideHorizontalSpriteBand(localPoint) {
            return nil
        }

        guard let win = window, win.windowNumber > 0 else { return nil }
        let windowID = CGWindowID(win.windowNumber)

        let screenPoint = win.convertPoint(toScreen: convert(localPoint, to: nil))
        let captureRect = Self.cgCaptureRectForScreenPoint(screenPoint)

        guard let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Self.pixelLooksLikeSolidSprite(pixel) ? self : nil
    }

    /// Same rules as `hitTest` but without needing an `NSEvent` — used with `NSWindow.ignoresMouseEvents`.
    func shouldAcceptMouseHit(atLocalPoint localPoint: NSPoint) -> Bool {
        guard bounds.contains(localPoint) else { return false }

        if localPoint.y > interactiveRegionMaxY {
            return false
        }
        if localPoint.y < dockPassThroughMaxY {
            return false
        }
        if isOutsideHorizontalSpriteBand(localPoint) {
            return false
        }

        guard let win = window, win.windowNumber > 0 else { return false }
        let windowID = CGWindowID(win.windowNumber)
        let screenPoint = win.convertPoint(toScreen: convert(localPoint, to: nil))
        let captureRect = Self.cgCaptureRectForScreenPoint(screenPoint)

        guard let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return false
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Self.pixelLooksLikeSolidSprite(pixel)
    }

    /// Rejects faint edges and opaque-black HEVC letterboxing that still reads as alpha > 0.
    private static func pixelLooksLikeSolidSprite(_ pixel: [UInt8]) -> Bool {
        let a = pixel[3]
        guard a >= minHitAlphaStatic else { return false }
        let r = Float(pixel[0]), g = Float(pixel[1]), b = Float(pixel[2])
        let mx = max(r, max(g, b))
        if mx < 22 && (r + g + b) < 58 { return false }
        return true
    }

    private static let minHitAlphaStatic: UInt8 = 56

    override func mouseDown(with event: NSEvent) {
        character?.handleClick()
    }
}
