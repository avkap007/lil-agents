import AppKit

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class NonKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

class CharacterContentView: NSView {
    weak var character: WalkerCharacter?

    override var isOpaque: Bool { false }

    /// Portrait video has a lot of transparent canvas above the sprite. Only the lower
    /// fraction of the view (near the Dock) should be eligible for hits — clicks “above”
    /// the character must pass through to windows below.
    private var interactiveRegionMaxY: CGFloat {
        bounds.height * 0.50
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // NSView origin is bottom-left: small Y = near Dock / feet, large Y = empty sky.
        if localPoint.y > interactiveRegionMaxY {
            return nil
        }

        // AVPlayerLayer is GPU-rendered so layer.render(in:) won't capture video pixels.
        // Use CGWindowListCreateImage to sample actual on-screen alpha at click point.
        let screenPoint = window?.convertPoint(toScreen: convert(localPoint, to: nil)) ?? .zero
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - screenPoint.y

        let captureRect = CGRect(x: screenPoint.x - 0.5, y: flippedY - 0.5, width: 1, height: 1)
        guard let windowID = window?.windowNumber, windowID > 0 else { return nil }

        guard let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            // No sample — pass through (never steal Dock/desktop clicks with a fat fallback rect).
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
        // Transparent or near-transparent: let clicks reach the Dock / Finder.
        return pixel[3] > 40 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        character?.handleClick()
    }
}
