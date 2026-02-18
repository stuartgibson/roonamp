//
//  WinampSkinView.swift
//  Roonamp
//
//  Shared components used by both main window (CALayer) and playlist/windowshade (SwiftUI).
//

import SwiftUI
import Combine

// Environment key for pixel-perfect scaling (avoids bilinear .scaleEffect)
private struct WinampScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 2.0
}
extension EnvironmentValues {
    var winampScale: CGFloat {
        get { self[WinampScaleKey.self] }
        set { self[WinampScaleKey.self] = newValue }
    }
}

// MARK: - Winamp Visualizer

private class VisualizerPeaks {
    var values: [Double]
    init(count: Int) { values = Array(repeating: 0, count: count) }
}

enum VisualizerMode: CaseIterable {
    case spectrum
    case oscilloscope
    case off
}

// MARK: - Visualizer rendering engine (bypasses SwiftUI image pipeline)

/// Manages a persistent pixel buffer and renders visualizer frames via CALayer.
final class VisualizerRenderer {
    let sourceWidth: Int
    let sourceHeight: Int
    let barCount: Int
    let devicePixelScale: Int
    let imgWidth: Int
    let imgHeight: Int
    let bytesPerRow: Int

    // Pre-computed pixel data (row 0 = top of screen in memory)
    let backgroundPixels: UnsafeMutablePointer<UInt32>
    let barRowColors: UnsafeMutablePointer<UInt32>   // sourceHeight entries, index 0 = top of screen
    let peakColor: UInt32
    let oscColors: UnsafeMutablePointer<UInt32>      // 5 entries
    let pixelCount: Int

    // Reusable frame buffer
    let frameBuffer: UnsafeMutablePointer<UInt32>

    // Peak state
    var peakValues: UnsafeMutablePointer<Double>

    // Spectrum data
    static let spectrumData: Data? = {
        guard let url = Bundle.main.url(forResource: "spectrum_data", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data
    }()
    static let spectrumBands = 19
    static var spectrumFrameCount: Int {
        (spectrumData?.count ?? 0) / spectrumBands
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(colors: [Color], sourceWidth: Int = 76, sourceHeight: Int = 16,
         barCount: Int = 19, scale: CGFloat) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.barCount = barCount

        let backing = NSScreen.main?.backingScaleFactor ?? 2.0
        let ps = max(1, Int(scale * backing))
        self.devicePixelScale = ps
        let iW = sourceWidth * ps
        let iH = sourceHeight * ps
        self.imgWidth = iW
        self.imgHeight = iH
        self.bytesPerRow = iW * 4
        self.pixelCount = iW * iH

        // Pack CGColor → UInt32 (noneSkipLast on little-endian: memory is R,G,B,X → UInt32 = X<<24|B<<16|G<<8|R)
        let allCGColors = colors.map { NSColor($0).usingColorSpace(.sRGB)?.cgColor ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1) }
        func pack(_ c: CGColor) -> UInt32 {
            let srgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c
            let n = srgb.numberOfComponents
            let comp = srgb.components ?? [0, 0, 0, 1]
            let r = UInt32(max(0, min(255, Int(comp[0] * 255))))
            let g = UInt32(n > 1 ? max(0, min(255, Int(comp[1] * 255))) : 0)
            let b = UInt32(n > 2 ? max(0, min(255, Int(comp[2] * 255))) : 0)
            return r | (g << 8) | (b << 16) | (0xFF << 24)
        }

        let bgPacked = allCGColors.count > 0 ? pack(allCGColors[0]) : 0xFF000000
        let gridPacked = allCGColors.count > 1 ? pack(allCGColors[1]) : 0xFF000000
        self.peakColor = allCGColors.count > 23 ? pack(allCGColors[23]) : 0xFFFFFFFF

        self.oscColors = .allocate(capacity: 5)
        var oi = 0
        while oi < 5 {
            let idx = 18 + oi
            oscColors[oi] = idx < allCGColors.count ? pack(allCGColors[idx]) : 0xFF00FF00
            oi += 1
        }

        // Build background pixels (row 0 = top of screen)
        self.backgroundPixels = .allocate(capacity: iW * iH)
        // Fill with background color
        var pi = 0
        while pi < iW * iH {
            backgroundPixels[pi] = bgPacked
            pi += 1
        }
        // Grid dots at every other source pixel
        var gy = 0
        while gy < sourceHeight {
            var gx = 0
            while gx < sourceWidth {
                // Fill the ps×ps block for this grid dot
                var dy = 0
                while dy < ps {
                    let row = gy * ps + dy
                    var dx = 0
                    while dx < ps {
                        backgroundPixels[row * iW + gx * ps + dx] = gridPacked
                        dx += 1
                    }
                    dy += 1
                }
                gx += 2
            }
            gy += 2
        }

        // Bar row colors: index by screen row (0=top). Top of vis = ci=3, bottom = ci=17
        self.barRowColors = .allocate(capacity: sourceHeight)
        var sy = 0
        while sy < sourceHeight {
            // sy=0 is top of screen → corresponds to py=sourceHeight-1 (top of bar, cool)
            let py = sourceHeight - 1 - sy
            let scaledPy = sourceHeight >= 16 ? (py & ~1) : Int(Double(py) / Double(sourceHeight - 1) * 16) & ~1
            let ci = min(17, 17 - scaledPy)
            barRowColors[sy] = ci >= 0 && ci < allCGColors.count ? pack(allCGColors[ci]) : 0xFF00FF00
            sy += 1
        }

        self.frameBuffer = .allocate(capacity: iW * iH)
        self.peakValues = .allocate(capacity: barCount)
        var pvi = 0
        while pvi < barCount {
            peakValues[pvi] = 0
            pvi += 1
        }
    }

    deinit {
        backgroundPixels.deallocate()
        barRowColors.deallocate()
        oscColors.deallocate()
        frameBuffer.deallocate()
        peakValues.deallocate()
    }

    func renderFrame(time: Double, mode: VisualizerMode, isPlaying: Bool) -> CGImage? {
        let iW = imgWidth
        let iH = imgHeight
        let ps = devicePixelScale
        let h = sourceHeight
        let w = sourceWidth

        // Copy background to frame buffer
        memcpy(frameBuffer, backgroundPixels, pixelCount * 4)

        if isPlaying && mode != .off {
            switch mode {
            case .spectrum:
                let barW = 3 * ps
                var i = 0
                while i < barCount {
                    let amplitude = amplitudeForBar(i, time: time)
                    if amplitude >= peakValues[i] {
                        peakValues[i] = amplitude
                    } else {
                        peakValues[i] = max(0, peakValues[i] - 0.02)
                    }
                    let barHeight = Int(amplitude * Double(h))
                    if barHeight > 0 {
                        let sx = i * 4 * ps
                        let topRow = (h - barHeight) * ps
                        let bottomRow = h * ps
                        var row = topRow
                        while row < bottomRow {
                            let screenY = row / ps  // source screen y
                            let color = barRowColors[screenY]
                            let rowBase = row * iW + sx
                            var col = 0
                            while col < barW {
                                frameBuffer[rowBase + col] = color
                                col += 1
                            }
                            row += 1
                        }
                    }
                    // Peak dot
                    let peakPixel = Int(peakValues[i] * Double(h - 1))
                    if peakPixel > 0 {
                        let sx = i * 4 * ps
                        let peakScreenY = (h - 1 - peakPixel) * ps
                        var dy = 0
                        while dy < ps {
                            let rowBase = (peakScreenY + dy) * iW + sx
                            var col = 0
                            while col < barW {
                                frameBuffer[rowBase + col] = peakColor
                                col += 1
                            }
                            dy += 1
                        }
                    }
                    i += 1
                }
            case .oscilloscope:
                var bandAmps = [Double](repeating: 0, count: barCount)
                var i = 0
                while i < barCount {
                    bandAmps[i] = amplitudeForBar(i, time: time)
                    i += 1
                }
                var x = 0
                while x < w {
                    let bandPos = Double(x) / Double(w - 1) * Double(barCount - 1)
                    let lo = Int(bandPos)
                    let hi = min(lo + 1, barCount - 1)
                    let frac = bandPos - Double(lo)
                    let amp = bandAmps[lo] * (1 - frac) + bandAmps[hi] * frac
                    let screenY = max(0, min(h - 1, Int(Double(h - 1) * (1 - amp))))
                    let dist = abs(screenY - h / 2)
                    let maxDist = h / 2
                    let ci: Int
                    if maxDist <= 3 {
                        ci = dist == 0 ? 0 : dist == 1 ? 2 : 4
                    } else {
                        ci = dist <= 1 ? 0 : dist <= 3 ? 1 : dist <= 5 ? 2 : dist <= 6 ? 3 : 4
                    }
                    let color = oscColors[ci]
                    var dy = 0
                    while dy < ps {
                        let rowBase = (screenY * ps + dy) * iW + x * ps
                        var dx = 0
                        while dx < ps {
                            frameBuffer[rowBase + dx] = color
                            dx += 1
                        }
                        dy += 1
                    }
                    x += 1
                }
            case .off: break
            }
        }

        // Create CGImage directly from frame buffer (no copy via CFData retain)
        guard let provider = CGDataProvider(dataInfo: nil,
                                             data: frameBuffer,
                                             size: pixelCount * 4,
                                             releaseData: { _, _, _ in }) else { return nil }
        return CGImage(width: iW, height: iH,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: iW * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func amplitudeForBar(_ i: Int, time: Double) -> Double {
        let bandIndex = barCount < Self.spectrumBands
            ? Int(Double(i) / Double(barCount) * Double(Self.spectrumBands))
            : i
        guard let data = Self.spectrumData, Self.spectrumFrameCount > 0 else {
            let freq = Double(bandIndex) / Double(Self.spectrumBands)
            let base = (1.0 - freq * 0.5) * 0.55
            return max(0, min(1, base + sin(time * 2.3 + Double(bandIndex) * 0.5) * 0.25))
        }
        let frameIndex = Int(time * 30) % Self.spectrumFrameCount
        let offset = frameIndex * Self.spectrumBands + min(bandIndex, Self.spectrumBands - 1)
        return Double(data[offset]) / 255.0
    }
}

/// NSView that renders the visualizer directly via CALayer, bypassing SwiftUI image pipeline.
final class VisualizerLayerView: NSView {
    var renderer: VisualizerRenderer?
    var mode: VisualizerMode = .spectrum
    var isPlaying: Bool = false
    var colorHash: Int = 0
    private var renderTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError() }

    func startRenderTimer() {
        guard renderTimer == nil else { return }
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if let image = self.renderer?.renderFrame(time: now, mode: self.mode, isPlaying: self.isPlaying) {
                self.layer?.contents = image
            }
        }
    }

    func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
        // Render one static frame
        if let image = renderer?.renderFrame(time: 0, mode: mode, isPlaying: isPlaying) {
            layer?.contents = image
        }
    }

    func updateAnimation() {
        let shouldAnimate = isPlaying && mode != .off
        if shouldAnimate {
            startRenderTimer()
        } else {
            stopRenderTimer()
        }
    }

    deinit {
        renderTimer?.invalidate()
    }
}

struct WinampVisualizer: View {
    let colors: [Color]
    let isPlaying: Bool
    let region: WinampSkin.ButtonRegion
    let scale: CGFloat
    @Binding var mode: VisualizerMode
    var handleTapCycle: Bool = true

    private let width: Int
    private let height: Int
    private let barCount: Int

    init(colors: [Color], isPlaying: Bool, region: WinampSkin.ButtonRegion, scale: CGFloat,
         mode: Binding<VisualizerMode>, handleTapCycle: Bool = true,
         sourceWidth: Int = 76, sourceHeight: Int = 16, barCount: Int = 19) {
        self.colors = colors
        self.isPlaying = isPlaying
        self.region = region
        self.scale = scale
        self._mode = mode
        self.handleTapCycle = handleTapCycle
        self.width = sourceWidth
        self.height = sourceHeight
        self.barCount = barCount
    }

    var body: some View {
        VisualizerNSViewRepresentable(
            colors: colors, isPlaying: isPlaying, mode: mode,
            scale: scale, sourceWidth: width, sourceHeight: height, barCount: barCount
        )
        .frame(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        .contentShape(Rectangle())
        .onTapGesture {
            if handleTapCycle {
                let all = VisualizerMode.allCases
                let idx = all.firstIndex(of: mode) ?? 0
                mode = all[(idx + 1) % all.count]
            }
        }
        .allowsHitTesting(handleTapCycle)
        .padding(.leading, CGFloat(region.x) * scale)
        .padding(.top, CGFloat(region.y) * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct VisualizerNSViewRepresentable: NSViewRepresentable {
    let colors: [Color]
    let colorHash: Int
    let isPlaying: Bool
    let mode: VisualizerMode
    let scale: CGFloat
    let sourceWidth: Int
    let sourceHeight: Int
    let barCount: Int

    init(colors: [Color], isPlaying: Bool, mode: VisualizerMode,
         scale: CGFloat, sourceWidth: Int, sourceHeight: Int, barCount: Int) {
        self.colors = colors
        self.isPlaying = isPlaying
        self.mode = mode
        self.scale = scale
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.barCount = barCount
        // Stable hash from actual color component values
        var h = 0
        for c in colors {
            if let cg = NSColor(c).usingColorSpace(.sRGB) {
                h = h &* 31 &+ Int(cg.redComponent * 255) &+ Int(cg.greenComponent * 255) &* 17 &+ Int(cg.blueComponent * 255) &* 31
            }
        }
        self.colorHash = h
    }

    func makeNSView(context: Context) -> VisualizerLayerView {
        let view = VisualizerLayerView(frame: .zero)
        view.colorHash = colorHash
        view.renderer = VisualizerRenderer(colors: colors, sourceWidth: sourceWidth,
                                            sourceHeight: sourceHeight, barCount: barCount, scale: scale)
        view.mode = mode
        view.isPlaying = isPlaying
        view.updateAnimation()
        return view
    }

    func updateNSView(_ view: VisualizerLayerView, context: Context) {
        if view.colorHash != colorHash {
            view.colorHash = colorHash
            view.renderer = VisualizerRenderer(colors: colors, sourceWidth: sourceWidth,
                                                sourceHeight: sourceHeight, barCount: barCount, scale: scale)
        }
        view.mode = mode
        view.isPlaying = isPlaying
        view.updateAnimation()
    }
}

// MARK: - Winamp Title Bar (used by windowshade)

struct WinampTitleBar {
    struct TitleButton {
        let region: WinampSkin.ButtonRegion
        let normalX: CGFloat
        let normalY: CGFloat
        let pressedX: CGFloat
        let pressedY: CGFloat
    }
}

struct WinampTitleBarButton: View {
    let bitmap: NSImage
    let button: WinampTitleBar.TitleButton
    let action: () -> Void
    @Environment(\.winampScale) private var scale

    @State private var isPressed = false

    var body: some View {
        if let sprite = extractSprite() {
            Image(nsImage: sprite)
                .resizable()
                .interpolation(.none)
                .frame(width: CGFloat(button.region.width) * scale, height: CGFloat(button.region.height) * scale)
                .offset(x: CGFloat(button.region.x) * scale, y: CGFloat(button.region.y) * scale)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPressed = true }
                        .onEnded { _ in
                            isPressed = false
                            action()
                        }
                )
        }
    }

    private func extractSprite() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let x = isPressed ? button.pressedX : button.normalX
        let y = isPressed ? button.pressedY : button.normalY
        let sourceRect = CGRect(x: x, y: y, width: 9, height: 9)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 9, height: 9))
    }
}

// MARK: - Winamp Bitmap Text (used by windowshade)

struct WinampBitmapText: View {
    let text: String
    let bitmap: NSImage
    let region: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollTimer: Timer?
    @State private var scrollDirection: CGFloat = 1.0
    @State private var cachedImage: NSImage?
    @State private var cachedText: String = ""
    @State private var cachedBitmap: NSImage?

    var body: some View {
        let renderedText = getCachedRenderedText()
        Group {
            if let renderedText {
                let textWidth = renderedText.size.width
                let regionWidth = CGFloat(region.width)
                let needsScrolling = textWidth > regionWidth

                ZStack(alignment: .leading) {
                    Image(nsImage: renderedText)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: textWidth * scale, height: 6 * scale)
                        .offset(x: needsScrolling ? -scrollOffset * scale : 0)
                }
                .frame(width: regionWidth * scale, height: 6 * scale, alignment: .leading)
                .clipped()
                .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
                .onAppear {
                    if needsScrolling {
                        startScrolling(textWidth: textWidth, regionWidth: regionWidth)
                    }
                }
                .onChange(of: text) {
                    stopScrolling()
                    if needsScrolling {
                        startScrolling(textWidth: textWidth, regionWidth: regionWidth)
                    }
                }
                .onDisappear {
                    stopScrolling()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func getCachedRenderedText() -> NSImage? {
        if text == cachedText && bitmap === cachedBitmap, let cached = cachedImage {
            return cached
        }
        let rendered = renderBitmapText()
        DispatchQueue.main.async {
            cachedText = text
            cachedBitmap = bitmap
            cachedImage = rendered
        }
        return rendered
    }

    private func startScrolling(textWidth: CGFloat, regionWidth: CGFloat) {
        scrollOffset = 0
        scrollDirection = 1.0
        let maxScroll = textWidth - regionWidth + 10

        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            scrollOffset += scrollDirection * 0.5

            if scrollOffset >= maxScroll {
                scrollDirection = -1.0
                scrollOffset = maxScroll
            } else if scrollOffset <= 0 {
                scrollDirection = 1.0
                scrollOffset = 0
            }
        }
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func renderBitmapText() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6
        let spacing: CGFloat = 1

        let upperText = text.uppercased()
        let totalWidth = CGFloat(upperText.count) * (charWidth + spacing)

        let renderedImage = NSImage(size: NSSize(width: totalWidth, height: charHeight))

        renderedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        var xOffset: CGFloat = 0

        for char in upperText {
            if let charImage = extractCharacter(char, from: cgImage, charWidth: charWidth, charHeight: charHeight) {
                charImage.draw(at: NSPoint(x: xOffset, y: 0),
                              from: NSRect(origin: .zero, size: charImage.size),
                              operation: .copy,
                              fraction: 1.0)
            }
            xOffset += charWidth + spacing
        }

        renderedImage.unlockFocus()

        return renderedImage
    }

    private func extractCharacter(_ char: Character, from cgImage: CGImage, charWidth: CGFloat, charHeight: CGFloat) -> NSImage? {
        let row0 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@   "
        let row1 = "0123456789 .:()-\'!_+\\/[]^&%,=$#"
        let row2 = "  ?*                            "

        let charMaps = [row0, row1, row2]

        // Handle space - return blank
        if char == " " {
            return NSImage(size: NSSize(width: charWidth, height: charHeight))
        }

        // Find character in the map
        for (rowIndex, charMap) in charMaps.enumerated() {
            if let index = charMap.firstIndex(of: char) {
                let col = charMap.distance(from: charMap.startIndex, to: index)

                let yPosition = CGFloat(rowIndex) * charHeight

                let sourceRect = CGRect(
                    x: CGFloat(col) * charWidth,
                    y: yPosition,
                    width: charWidth,
                    height: charHeight
                )

                guard let croppedCGImage = cgImage.cropping(to: sourceRect) else {
                    return nil
                }

                return NSImage(cgImage: croppedCGImage, size: NSSize(width: charWidth, height: charHeight))
            }
        }

        // Unknown character - return blank
        return NSImage(size: NSSize(width: charWidth, height: charHeight))
    }
}

// MARK: - Winamp Info Display (used by windowshade for time)

struct WinampInfoDisplay: View {
    let text: String
    let bitmap: NSImage
    let region: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    @State private var cachedImage: NSImage?
    @State private var cachedText: String = ""
    @State private var cachedBitmap: NSImage?

    var body: some View {
        let rendered = getCachedRenderedText()
        Group {
            if let rendered {
                Image(nsImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: rendered.size.width * scale, height: rendered.size.height * scale)
                    .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func getCachedRenderedText() -> NSImage? {
        if text == cachedText && bitmap === cachedBitmap, let cached = cachedImage {
            return cached
        }
        let rendered = renderText()
        DispatchQueue.main.async {
            cachedText = text
            cachedBitmap = bitmap
            cachedImage = rendered
        }
        return rendered
    }

    private func renderText() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6

        let totalWidth = CGFloat(text.count) * charWidth
        let renderedImage = NSImage(size: NSSize(width: totalWidth, height: charHeight))

        renderedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        var xOffset: CGFloat = 0
        for char in text.uppercased() {
            if let charImage = extractCharacter(char, from: cgImage, charWidth: charWidth, charHeight: charHeight) {
                charImage.draw(at: NSPoint(x: xOffset, y: 0),
                              from: NSRect(origin: .zero, size: charImage.size),
                              operation: .copy,
                              fraction: 1.0)
            }
            xOffset += charWidth
        }

        renderedImage.unlockFocus()
        return renderedImage
    }

    private func extractCharacter(_ char: Character, from cgImage: CGImage, charWidth: CGFloat, charHeight: CGFloat) -> NSImage? {
        let row0 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@   "
        let row1 = "0123456789 .:()-\'!_+\\/[]^&%,=$#"
        let row2 = "  ?*                            "
        let charMaps = [row0, row1, row2]

        if char == " " {
            return NSImage(size: NSSize(width: charWidth, height: charHeight))
        }

        for (rowIndex, charMap) in charMaps.enumerated() {
            if let index = charMap.firstIndex(of: char) {
                let col = charMap.distance(from: charMap.startIndex, to: index)
                let yPosition = CGFloat(rowIndex) * charHeight
                let sourceRect = CGRect(x: CGFloat(col) * charWidth, y: yPosition, width: charWidth, height: charHeight)
                guard let croppedCGImage = cgImage.cropping(to: sourceRect) else { return nil }
                return NSImage(cgImage: croppedCGImage, size: NSSize(width: charWidth, height: charHeight))
            }
        }
        return NSImage(size: NSSize(width: charWidth, height: charHeight))
    }
}

/// Blocks window dragging in an area so SwiftUI gestures can handle drags instead
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NoDragView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Window Region Shape

/// Clips the window content to the polygons defined in region.txt
struct WinampRegionShape: Shape {
    let polygons: [[CGPoint]]?
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        guard let polygons = polygons, !polygons.isEmpty else {
            return Path(rect)
        }
        var path = Path()
        for polygon in polygons {
            guard polygon.count >= 3 else { continue }
            var poly = Path()
            poly.move(to: CGPoint(x: polygon[0].x * scale, y: polygon[0].y * scale))
            for i in 1..<polygon.count {
                poly.addLine(to: CGPoint(x: polygon[i].x * scale, y: polygon[i].y * scale))
            }
            poly.closeSubpath()
            path.addPath(poly)
        }
        return path
    }
}

#if os(macOS)
import AppKit

enum WinampWindow {
    static weak var current: NSWindow?
    static weak var playlist: NSWindow?
    static weak var albumArt: NSWindow?
    static var isSnapped: Bool = false {
        didSet {
            guard isSnapped != oldValue else { return }
            if isSnapped {
                if let main = current, let pl = playlist,
                   !(main.childWindows?.contains(pl) ?? false) {
                    main.addChildWindow(pl, ordered: .below)
                }
            } else {
                if let main = current, let pl = playlist {
                    main.removeChildWindow(pl)
                }
            }
        }
    }
    static var snapOffset: NSPoint = .zero
    static var isMovingProgrammatically: Bool = false
    static var isPlaylistDragging: Bool = false
}


struct WindowAccessorWinamp: NSViewRepresentable {
    let scale: CGFloat
    let isWindowShade: Bool
    let hasRegion: Bool
    @Binding var isWindowActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                WinampWindow.current = window
                self.configureWindow(window)
                window.delegate = context.coordinator
                context.coordinator.window = window

                // Listen for alwaysOnTop changes
                NotificationCenter.default.addObserver(
                    forName: .alwaysOnTopChanged,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let alwaysOnTop = notification.object as? Bool {
                        window.level = alwaysOnTop ? .floating : .normal
                    }
                }

                // When main window moves while snapped, update saved playlist frame
                // so reopening the playlist places it at the correct position
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    guard WinampWindow.isSnapped else { return }
                    let mainFrame = window.frame
                    if let pl = WinampWindow.playlist, pl.isVisible {
                        // Playlist is visible — its own didMove observer saves its frame
                    } else {
                        // Playlist is hidden — save the expected snap position
                        let expectedX = mainFrame.origin.x + WinampWindow.snapOffset.x
                        let expectedY = mainFrame.origin.y + WinampWindow.snapOffset.y
                        let defaults = UserDefaults.standard
                        let oldW = defaults.double(forKey: "playlistWindowW")
                        let oldH = defaults.double(forKey: "playlistWindowH")
                        guard oldW > 0, oldH > 0 else { return }
                        defaults.set(expectedX, forKey: "playlistWindowX")
                        defaults.set(expectedY, forKey: "playlistWindowY")
                    }
                }

                // Track app active state for titlebar
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { _ in isWindowActive = true }
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { _ in isWindowActive = false }

            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            DispatchQueue.main.async {
                self.configureWindow(window)
            }
        }
    }

    private func configureWindow(_ window: NSWindow) {
        let height: CGFloat = isWindowShade ? CGFloat(WinampSkin.windowShadeHeight) : 116
        let size = NSSize(width: 275 * scale, height: height * scale)

        // Completely borderless - no title bar at all
        window.styleMask = [.borderless, .miniaturizable]

        // Anchor resize to top-left: preserve the top of the window frame
        let oldFrame = window.frame
        let newOriginY = oldFrame.maxY - size.height
        let newFrame = NSRect(x: oldFrame.minX, y: newOriginY, width: size.width, height: size.height)
        if window.frame.size != size {
            window.setFrame(newFrame, display: true, animate: false)
        }
        window.minSize = size
        window.maxSize = size

        // Make window movable by dragging anywhere
        window.isMovableByWindowBackground = true

        // Transparent background for shaped windows (region.txt), near-zero alpha
        // for rectangular windows to prevent macOS click-through on borderless windows
        window.isOpaque = false
        window.backgroundColor = hasRegion ? .clear : NSColor(white: 0, alpha: 0.005)

        // No shadow (Winamp classic didn't have shadows)
        window.hasShadow = false

        // Set window level based on preference
        let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        window.level = alwaysOnTop ? .floating : .normal
    }

    class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        private var dragMonitor: Any?
        private var mouseUpMonitor: Any?

        func windowWillMove(_ notification: Notification) {
            // When snapped, child window handles movement automatically.
            // Only set up snap detection when not snapped.
            if !WinampWindow.isSnapped {
                startDragMonitors()
            }
        }

        private func startDragMonitors() {
            if dragMonitor == nil {
                dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                    self?.checkSnapDuringDrag()
                    return event
                }
            }
            if mouseUpMonitor == nil {
                mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                    self?.cleanupMonitors()
                    return event
                }
            }
        }

        private func checkSnapDuringDrag() {
            guard !WinampWindow.isSnapped,
                  !WinampWindow.isPlaylistDragging,
                  let mainWindow = window,
                  let playlistWindow = WinampWindow.playlist else { return }
            let mainFrame = mainWindow.frame
            let plFrame = playlistWindow.frame
            let snapDistance: CGFloat = 25
            let leftAligned = abs(plFrame.minX - mainFrame.minX) < snapDistance

            let mainBottomNearPlTop = abs(mainFrame.minY - plFrame.maxY) < snapDistance
            let mainTopNearPlBottom = abs(mainFrame.maxY - plFrame.minY) < snapDistance

            if mainBottomNearPlTop && leftAligned {
                let snappedOrigin = NSPoint(x: mainFrame.minX, y: mainFrame.minY - plFrame.height)
                WinampWindow.isMovingProgrammatically = true
                playlistWindow.setFrameOrigin(snappedOrigin)
                WinampWindow.isMovingProgrammatically = false
                WinampWindow.isSnapped = true
                WinampWindow.snapOffset = NSPoint(
                    x: snappedOrigin.x - mainFrame.origin.x,
                    y: snappedOrigin.y - mainFrame.origin.y
                )
                cleanupMonitors()
            } else if mainTopNearPlBottom && leftAligned {
                let snappedOrigin = NSPoint(x: mainFrame.minX, y: mainFrame.maxY)
                WinampWindow.isMovingProgrammatically = true
                playlistWindow.setFrameOrigin(snappedOrigin)
                WinampWindow.isMovingProgrammatically = false
                WinampWindow.isSnapped = true
                WinampWindow.snapOffset = NSPoint(
                    x: snappedOrigin.x - mainFrame.origin.x,
                    y: snappedOrigin.y - mainFrame.origin.y
                )
                cleanupMonitors()
            }
        }

        private func cleanupMonitors() {
            if let monitor = dragMonitor {
                NSEvent.removeMonitor(monitor)
                dragMonitor = nil
            }
            if let monitor = mouseUpMonitor {
                NSEvent.removeMonitor(monitor)
                mouseUpMonitor = nil
            }
        }

        deinit {
            cleanupMonitors()
        }
    }
}
#endif

// MARK: - Winamp Windowshade View

struct WinampWindowShadeView: View {
    let skin: WinampSkin
    let isWindowActive: Bool
    let currentSeekPosition: Int
    @Binding var showRemaining: Bool
    @Binding var displayMode: WSDisplayMode
    let onOptions: () -> Void
    let onUnshade: () -> Void
    let onMinimize: () -> Void
    let onClose: () -> Void
    let onSeek: (Double) -> Void
    @EnvironmentObject var roonAPI: RoonAPI
    @EnvironmentObject var playback: PlaybackState
    @Environment(\.winampScale) private var scale

    enum WSDisplayMode: String, CaseIterable {
        case spectrum, oscilloscope, trackInfo, off
    }

    private let wsWidth: CGFloat = 275
    private let wsHeight: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background — contains all static graphics (transport buttons, position track, etc.)
            if let titleBarBitmap = skin.titleBarBitmap,
               let bgImage = extractWindowShadeBackground(from: titleBarBitmap) {
                Image(nsImage: bgImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: wsWidth * scale, height: wsHeight * scale)
                    .onTapGesture(count: 2) {
                        onUnshade()
                    }
            }

            // First dark rectangle: visualizer, track info, or off — single tap target
            wsVisualizerArea()

            // Playback time in the second dark rectangle, right-aligned
            if let textBitmap = skin.textBitmap {
                let seekPos = playback.state == .playing
                    ? currentSeekPosition
                    : playback.seekPosition
                let timeText = formatCompactTime(seekPos)
                let charWidth = 5
                let textWidth = timeText.count * charWidth
                let rightEdge = WinampSkin.wsTimeRegion.x + WinampSkin.wsTimeRegion.width
                let alignedRegion = WinampSkin.ButtonRegion(
                    x: rightEdge - textWidth,
                    y: WinampSkin.wsTimeRegion.y,
                    width: textWidth,
                    height: WinampSkin.wsTimeRegion.height
                )
                WinampInfoDisplay(
                    text: timeText,
                    bitmap: textBitmap,
                    region: alignedRegion
                )
                .onTapGesture {
                    showRemaining.toggle()
                }
            }

            // Invisible transport button hit targets (graphics are in the background)
            windowShadeTransportHitTargets()

            // Position bar thumb only (track is in the background)
            if let titleBarBitmap = skin.titleBarBitmap {
                windowShadePositionBar(titleBarBitmap: titleBarBitmap)
            }

            // Window control buttons (need sprites for pressed states)
            if let titleBarBitmap = skin.titleBarBitmap {
                // Options button (top-left)
                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.titleBarOptionsButton,
                    normalX: 0, normalY: 0, pressedX: 0, pressedY: 9
                )) { onOptions() }

                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.wsMinimizeButton,
                    normalX: 9, normalY: 0, pressedX: 9, pressedY: 9
                )) { onMinimize() }

                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.wsUnshadeButton,
                    normalX: 0, normalY: 27, pressedX: 9, pressedY: 27
                )) { onUnshade() }

                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.wsCloseButton,
                    normalX: 18, normalY: 0, pressedX: 18, pressedY: 9
                )) { onClose() }
            }
        }
        .frame(width: wsWidth * scale, height: wsHeight * scale)
    }

    @ViewBuilder
    private func wsVisualizerArea() -> some View {
        let region = WinampSkin.wsVisualizerRegion
        ZStack {
            switch displayMode {
            case .spectrum, .oscilloscope:
                let visMode: VisualizerMode = displayMode == .spectrum ? .spectrum : .oscilloscope
                WinampVisualizer(
                    colors: skin.visColors,
                    isPlaying: playback.state == .playing,
                    region: region,
                    scale: scale,
                    mode: .constant(visMode),
                    handleTapCycle: false,
                    sourceWidth: region.width,
                    sourceHeight: region.height,
                    barCount: region.width / 4
                )
                .allowsHitTesting(false)
            case .trackInfo:
                if let nowPlaying = playback.nowPlaying,
                   let textBitmap = skin.textBitmap {
                    WinampBitmapText(
                        text: "\(nowPlaying.artist) - \(nowPlaying.title)",
                        bitmap: textBitmap,
                        region: region
                    )
                    .allowsHitTesting(false)
                }
            case .off:
                EmptyView()
            }

            // Single tap target covering the region
            Color.clear
                .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
                .contentShape(Rectangle())
                .onTapGesture { cycleDisplayMode() }
                .padding(.leading, CGFloat(region.x) * scale)
                .padding(.top, CGFloat(region.y) * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func cycleDisplayMode() {
        let all = WSDisplayMode.allCases
        let idx = all.firstIndex(of: displayMode) ?? 0
        displayMode = all[(idx + 1) % all.count]
    }

    private func formatCompactTime(_ seconds: Int) -> String {
        let timeToShow: Int
        let isNegative: Bool
        if showRemaining,
           let length = playback.nowPlaying?.length {
            timeToShow = max(0, length - seconds)
            isNegative = true
        } else {
            timeToShow = seconds
            isNegative = false
        }
        let m = timeToShow / 60
        let s = timeToShow % 60
        let prefix = isNegative ? "-" : ""
        return String(format: "%@%02d %02d", prefix, m, s)
    }

    private func extractWindowShadeBackground(from bitmap: NSImage) -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let y: CGFloat = isWindowActive ? 29 : 42
        let sourceRect = CGRect(x: 27, y: y, width: 275, height: 14)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 275, height: 14))
    }

    @ViewBuilder
    private func windowShadeTransportHitTargets() -> some View {
        // Invisible hit areas — the button graphics are baked into the background
        invisibleHitTarget(region: WinampSkin.wsPreviousButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.previous(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsPlayButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.playPause(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsPauseButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.playPause(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsStopButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.pause(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsNextButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.next(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsEjectButton) {
            // No eject action
        }
    }

    private func invisibleHitTarget(region: WinampSkin.ButtonRegion, action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .padding(.leading, CGFloat(region.x) * scale)
            .padding(.top, CGFloat(region.y) * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func windowShadePositionBar(titleBarBitmap: NSImage) -> some View {
        let region = WinampSkin.wsPositionBarRegion
        let length = playback.nowPlaying?.length ?? 0
        let seekPos = playback.state == .playing ? currentSeekPosition : playback.seekPosition
        let progress = length > 0 ? min(1.0, max(0.0, Double(seekPos) / Double(length))) : 0.0

        WinampWindowShadePositionBar(
            bitmap: titleBarBitmap,
            progress: progress,
            region: region,
            onSeek: onSeek
        )
    }
}

// MARK: - Windowshade Position Bar (thumb only — track is in background)

private struct WinampWindowShadePositionBar: View {
    let bitmap: NSImage       // titlebar.bmp
    let progress: Double
    let region: WinampSkin.ButtonRegion
    let onSeek: (Double) -> Void
    @Environment(\.winampScale) private var scale

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var dragStartProgress: Double = 0

    private let thumbWidth: CGFloat = 3
    private let barWidth: CGFloat = 17
    private let barHeight: CGFloat = 7

    var body: some View {
        ZStack(alignment: .leading) {
            // Invisible area matching the bar dimensions for gesture detection
            Color.clear
                .frame(width: barWidth * scale, height: barHeight * scale)

            // Thumb only — track background is baked into the windowshade background
            if let thumb = extractThumb() {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: thumbWidth * scale, height: barHeight * scale)
                    .offset(x: calculateThumbPosition())
                    .allowsHitTesting(false)
            }
        }
        .overlay(WindowDragBlocker())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let maxOffset = (barWidth - thumbWidth) * scale
                    if !isDragging {
                        isDragging = true
                        dragStartProgress = progress
                        dragProgress = dragStartProgress
                    }
                    let progressDelta = value.translation.width / maxOffset
                    dragProgress = max(0, min(1, dragStartProgress + progressDelta))
                }
                .onEnded { _ in
                    isDragging = false
                    onSeek(dragProgress)
                }
        )
        .padding(.leading, CGFloat(region.x) * scale)
        .padding(.top, CGFloat(region.y) * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var effectiveProgress: Double {
        isDragging ? dragProgress : progress
    }

    private func calculateThumbPosition() -> CGFloat {
        let maxOffset = (barWidth - thumbWidth) * scale
        return effectiveProgress * maxOffset
    }

    private func extractThumb() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sourceRect = CGRect(x: 20, y: 36, width: 3, height: 7)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 3, height: 7))
    }
}

#Preview {
    if let skinURL = Bundle.main.url(forResource: "base-2.91", withExtension: "wsz"),
       let skin = WinampSkinParser.parse(url: skinURL) {
        let api = RoonAPI(
            appInfo: RoonAppInfo(
                extensionId: "com.yourcompany.roonamp",
                displayName: "Roonamp",
                displayVersion: "1.0.0",
                publisher: "Your Name",
                email: "your.email@example.com"
            )
        )
        WinampMainBridge(skin: skin)
            .environmentObject(api)
            .environmentObject(api.playback)
            .environmentObject(WinampSkinManager())
    } else {
        Text("Failed to load skin")
    }
}
