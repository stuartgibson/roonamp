//
//  WinampMarquee.swift
//  Roonamp
//
//  The single implementation of Winamp's 5x6 bitmap-font text and its
//  character-stepped scrolling title. Both the main window title bar and the
//  windowshade track-info area render through here, so the two stay in step.
//
//  The scroll advances exactly one character per tick, as the original Winamp
//  did — deliberately juddery, not smooth. CoreAnimation reproduces that with a
//  discrete keyframe animation, which means the render server holds each step
//  and the app burns no CPU per frame.
//

import AppKit
import SwiftUI

// MARK: - Bitmap font

enum WinampBitmapFont {
    /// Glyph metrics of text.bmp. Every glyph is 5x6 with a 1px gap.
    static let charWidth: CGFloat = 5
    static let charHeight: CGFloat = 6
    static let spacing: CGFloat = 1

    /// Advance per glyph, which is also the scroll step: the title moves a whole
    /// character at a time.
    static var step: CGFloat { charWidth + spacing }

    /// Seconds each scroll step is held.
    static let stepInterval: TimeInterval = 0.5

    /// Extra travel past the right edge so the final character clears the region
    /// rather than sitting flush against it.
    static let overshoot: CGFloat = 10

    /// Rendered width of `text` in logical points.
    static func width(of text: String) -> CGFloat {
        CGFloat(text.uppercased().count) * step
    }

    /// Composites `text` into a single image using the skin's cached glyphs.
    /// Returns nil for empty text or when the context can't be created.
    static func render(_ text: String, sprites: SpriteCache) -> CGImage? {
        let upper = text.uppercased()
        guard !upper.isEmpty else { return nil }

        let totalWidth = width(of: upper)
        let pixelWidth = max(1, Int(totalWidth))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil,
                                 width: pixelWidth,
                                 height: Int(charHeight),
                                 bitsPerComponent: 8,
                                 bytesPerRow: pixelWidth * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: bitmapInfo.rawValue) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: totalWidth, height: charHeight))

        var xOff: CGFloat = 0
        for ch in upper {
            if let glyph = sprites.textChars[ch] {
                ctx.draw(glyph, in: CGRect(x: xOff, y: 0, width: charWidth, height: charHeight))
            }
            xOff += step
        }
        return ctx.makeImage()
    }
}

// MARK: - Marquee scrolling

enum WinampMarquee {
    private static let animationKey = "winampMarqueeScroll"

    /// The logical scroll offsets the title steps through, `0` first. Empty when
    /// the text already fits, in which case there is nothing to animate.
    ///
    /// The end point is rounded up to a whole step so the scroll always lands on
    /// a character boundary.
    static func offsets(contentWidth: CGFloat, regionWidth: CGFloat) -> [CGFloat] {
        guard contentWidth > regionWidth else { return [] }
        let step = WinampBitmapFont.step
        let raw = contentWidth - regionWidth + WinampBitmapFont.overshoot
        let maxScroll = (raw / step).rounded(.up) * step
        return stride(from: 0, through: maxScroll, by: step).map { $0 }
    }

    /// Drives `layer` back and forth through `positionsX` (absolute `position.x`
    /// values), holding each for one step. Pass fewer than two positions to stop
    /// scrolling.
    static func install(on layer: CALayer, positionsX: [CGFloat]) {
        layer.removeAnimation(forKey: animationKey)
        guard positionsX.count > 1 else { return }

        let anim = CAKeyframeAnimation(keyPath: "position.x")
        anim.values = positionsX
        // No interpolation between steps — this is what produces the original's
        // character-at-a-time judder instead of a smooth glide.
        anim.calculationMode = .discrete
        // Discrete mode bounds each held segment with a pair of key times, so it
        // needs one more entry than there are values.
        let count = positionsX.count
        anim.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        anim.duration = Double(count) * WinampBitmapFont.stepInterval
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: animationKey)
    }

    static func stop(on layer: CALayer) {
        layer.removeAnimation(forKey: animationKey)
    }

    /// Renders `text` into `textLayer` and (re)starts the scroll for it.
    ///
    /// `scale` lets a caller whose layer works in scaled pixels reuse the same
    /// logical geometry; pass 1 for an unscaled layer tree.
    static func apply(text: String,
                      sprites: SpriteCache,
                      textLayer: CALayer,
                      regionWidth: CGFloat,
                      scale: CGFloat = 1) {
        stop(on: textLayer)

        guard let image = WinampBitmapFont.render(text, sprites: sprites) else {
            textLayer.contents = nil
            textLayer.frame = CGRect(x: 0, y: 0, width: 0, height: WinampBitmapFont.charHeight * scale)
            return
        }

        let contentWidth = WinampBitmapFont.width(of: text)
        textLayer.contents = image
        textLayer.frame = CGRect(x: 0,
                                 y: 0,
                                 width: contentWidth * scale,
                                 height: WinampBitmapFont.charHeight * scale)

        // position.x is captured with the layer flush left, so every animated
        // value is that base minus the step offset.
        let base = textLayer.position.x
        let positions = offsets(contentWidth: contentWidth, regionWidth: regionWidth)
            .map { base - $0 * scale }
        install(on: textLayer, positionsX: positions)
    }
}

// MARK: - SwiftUI host

/// SwiftUI wrapper so the windowshade gets the same layer-backed marquee as the
/// main window instead of driving a scroll offset through view state.
struct WinampMarqueeText: View {
    let text: String
    let sprites: SpriteCache
    let region: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    var body: some View {
        MarqueeRepresentable(text: text, sprites: sprites, regionWidth: CGFloat(region.width), scale: scale)
            .frame(width: CGFloat(region.width) * scale,
                   height: WinampBitmapFont.charHeight * scale)
            .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct MarqueeRepresentable: NSViewRepresentable {
        let text: String
        let sprites: SpriteCache
        let regionWidth: CGFloat
        let scale: CGFloat

        func makeNSView(context: Context) -> MarqueeClipView {
            let view = MarqueeClipView()
            view.update(text: text, sprites: sprites, regionWidth: regionWidth, scale: scale)
            return view
        }

        func updateNSView(_ view: MarqueeClipView, context: Context) {
            view.update(text: text, sprites: sprites, regionWidth: regionWidth, scale: scale)
        }
    }

    /// Layer-backed clip region holding the scrolling text layer.
    final class MarqueeClipView: NSView {
        private let textLayer = CALayer()
        private var appliedText: String?
        private var appliedScale: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            textLayer.magnificationFilter = .nearest
            textLayer.minificationFilter = .nearest
            textLayer.contentsGravity = .resize
            // Suppress implicit animations; the marquee is the only animation here.
            textLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            textLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(textLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }

        func update(text: String, sprites: SpriteCache, regionWidth: CGFloat, scale: CGFloat) {
            // Re-rendering on every SwiftUI update would restart the scroll from
            // the left each time, so only redo the work when something changed.
            guard text != appliedText || scale != appliedScale else { return }
            appliedText = text
            appliedScale = scale
            WinampMarquee.apply(text: text,
                                sprites: sprites,
                                textLayer: textLayer,
                                regionWidth: regionWidth,
                                scale: scale)
        }
    }
}
