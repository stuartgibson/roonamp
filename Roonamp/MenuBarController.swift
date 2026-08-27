//
//  MenuBarController.swift
//  Roonamp
//
//  Optional menu bar item showing the currently playing Roon track.
//  The item never grows past the user's configured maximum width — longer
//  text scrolls horizontally (with a pause at the start of each loop).
//

import AppKit
import Combine

// MARK: - Preferences

enum MenuBarPrefs {
    static let enabledKey = "menuBarEnabled"
    static let maxWidthKey = "menuBarMaxWidth"
    static let showTrackKey = "menuBarShowTrack"
    static let showArtistKey = "menuBarShowArtist"
    static let showAlbumKey = "menuBarShowAlbum"

    static let defaultMaxWidth: Double = 180
    static let minMaxWidth: Double = 80
    static let maxMaxWidth: Double = 500

    static let defaultShowTrack = true
    static let defaultShowArtist = true
    static let defaultShowAlbum = false

    /// Separator between the enabled parts of the menu bar title.
    static let partSeparator = " \u{2013} "

    /// Reads a Bool that defaults to `fallback` when it has never been written.
    static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}

// MARK: - Scrolling text view

/// Draws a music-note glyph plus the now-playing text, clipped to the view's
/// width. When the text is wider than the available region it scrolls, looping
/// with a gap and pausing briefly each time it returns to the start.
final class MenuBarScrollingTextView: NSView {

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            measureText()
            resetScroll()
            updateWidth()
            needsDisplay = true
        }
    }

    /// Maximum total width of the status item, in points.
    var maxWidth: CGFloat = CGFloat(MenuBarPrefs.defaultMaxWidth) {
        didSet {
            guard maxWidth != oldValue else { return }
            resetScroll()
            updateWidth()
            needsDisplay = true
        }
    }

    /// Called whenever the desired status item width changes.
    var onWidthChange: ((CGFloat) -> Void)?

    /// Re-measures and pushes the current width to the status item. Needed once
    /// the view is installed, since the initial (empty) state changes nothing.
    func refreshLayout() {
        measureText()
        updateWidth()
        needsDisplay = true
    }

    // Layout metrics
    private let iconSize: CGFloat = 14
    private let iconGap: CGFloat = 4
    private let leadingInset: CGFloat = 5
    private let trailingInset: CGFloat = 5
    /// Blank space between the end of the text and the start of the next loop.
    private let loopGap: CGFloat = 28

    // Scroll animation
    private let scrollSpeed: CGFloat = 24       // points per second
    private let startPause: CFTimeInterval = 1.5
    private var offset: CGFloat = 0
    private var pauseUntil: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var timer: Timer?

    private var textWidth: CGFloat = 0
    private lazy var font: NSFont = .menuBarFont(ofSize: 13)

    // MARK: Lifecycle

    override var isFlipped: Bool { false }

    /// Clicks must reach the status item button underneath so its menu opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimer()
        } else {
            updateWidth()
            startTimerIfNeeded()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Measurement

    private var textRegionWidth: CGFloat {
        max(0, desiredWidth - leadingInset - iconSize - iconGap - trailingInset)
    }

    private var contentWidth: CGFloat {
        if text.isEmpty {
            return leadingInset + iconSize + trailingInset
        }
        return leadingInset + iconSize + iconGap + textWidth + trailingInset
    }

    private var desiredWidth: CGFloat {
        min(contentWidth, max(maxWidth, leadingInset + iconSize + trailingInset))
    }

    private var isScrolling: Bool {
        !text.isEmpty && textWidth > textRegionWidth + 0.5
    }

    private func measureText() {
        guard !text.isEmpty else {
            textWidth = 0
            return
        }
        let size = (text as NSString).size(withAttributes: [.font: font])
        textWidth = ceil(size.width)
    }

    private func updateWidth() {
        onWidthChange?(ceil(desiredWidth))
        startTimerIfNeeded()
    }

    private func resetScroll() {
        offset = 0
        pauseUntil = CACurrentMediaTime() + startPause
        lastTick = CACurrentMediaTime()
    }

    // MARK: Animation

    private func startTimerIfNeeded() {
        guard window != nil, isScrolling else {
            stopTimer()
            return
        }
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the ticker keeps moving while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = min(now - lastTick, 0.2)
        lastTick = now
        guard now >= pauseUntil else { return }

        offset += scrollSpeed * CGFloat(delta)
        let loopWidth = textWidth + loopGap
        if offset >= loopWidth {
            // The second copy has arrived exactly at the start position, so
            // snapping back to zero is seamless.
            offset = 0
            pauseUntil = now + startPause
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawContents()
        }
    }

    private func drawContents() {
        let color = NSColor.labelColor

        if let icon = tintedIcon(color: color) {
            let y = ((bounds.height - iconSize) / 2).rounded()
            icon.draw(in: CGRect(x: leadingInset, y: y, width: iconSize, height: iconSize))
        }

        guard !text.isEmpty else { return }

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        let textHeight = ceil(attributed.size().height)
        let y = ((bounds.height - textHeight) / 2).rounded()
        let originX = leadingInset + iconSize + iconGap

        let region = CGRect(x: originX, y: 0,
                            width: max(0, bounds.width - originX - trailingInset),
                            height: bounds.height)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: region).setClip()
        attributed.draw(at: CGPoint(x: originX - offset, y: y))
        if isScrolling {
            attributed.draw(at: CGPoint(x: originX - offset + textWidth + loopGap, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func tintedIcon(color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Roonamp") else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(config)
    }
}

// MARK: - Controller

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private let textView = MenuBarScrollingTextView()
    private weak var roonAPI: RoonAPI?
    private var playback: PlaybackState?
    private var cancellables = Set<AnyCancellable>()
    private var defaultsObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    /// Called once the SwiftUI scene has its RoonAPI instance.
    func configure(roonAPI: RoonAPI) {
        guard self.roonAPI == nil else { return }
        self.roonAPI = roonAPI
        self.playback = roonAPI.playback

        roonAPI.playback.$nowPlaying
            .combineLatest(roonAPI.playback.$state)
            .sink { [weak self] _, _ in
                self?.refreshText()
            }
            .store(in: &cancellables)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MenuBarController.shared.applyPreferences()
            }
        }

        applyPreferences()
    }

    // MARK: Preferences

    private func applyPreferences() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: MenuBarPrefs.enabledKey)
        let stored = defaults.object(forKey: MenuBarPrefs.maxWidthKey) as? Double
            ?? MenuBarPrefs.defaultMaxWidth
        let width = min(max(stored, MenuBarPrefs.minMaxWidth), MenuBarPrefs.maxMaxWidth)

        textView.maxWidth = CGFloat(width)

        if enabled {
            installStatusItem()
            refreshText()
        } else {
            removeStatusItem()
        }
    }

    // MARK: Status item

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        textView.onWidthChange = { [weak item] width in
            item?.length = width
        }

        if let button = item.button {
            button.title = ""
            button.image = nil
            textView.frame = button.bounds
            textView.autoresizingMask = [.width, .height]
            button.addSubview(textView)
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        statusItem = item
        refreshText()
        textView.refreshLayout()
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        textView.onWidthChange = nil
        textView.removeFromSuperview()
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    // MARK: Content

    private func refreshText() {
        guard statusItem != nil else { return }
        guard let np = playback?.nowPlaying else {
            textView.text = ""
            return
        }
        var parts: [String] = []
        if MenuBarPrefs.bool(MenuBarPrefs.showArtistKey, default: MenuBarPrefs.defaultShowArtist) {
            parts.append(np.artist)
        }
        if MenuBarPrefs.bool(MenuBarPrefs.showAlbumKey, default: MenuBarPrefs.defaultShowAlbum) {
            parts.append(np.album)
        }
        if MenuBarPrefs.bool(MenuBarPrefs.showTrackKey, default: MenuBarPrefs.defaultShowTrack) {
            parts.append(np.title)
        }

        // Empty fields are dropped so a missing album never leaves a dangling
        // separator. With every part switched off the item is icon-only.
        textView.text = parts
            .filter { !$0.isEmpty }
            .joined(separator: MenuBarPrefs.partSeparator)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let np = playback?.nowPlaying {
            menu.addItem(infoItem(np.title, font: .menuFont(ofSize: 13)))
            if !np.artist.isEmpty {
                menu.addItem(infoItem(np.artist, font: .menuFont(ofSize: 11)))
            }
            if !np.album.isEmpty {
                menu.addItem(infoItem(np.album, font: .menuFont(ofSize: 11)))
            }
        } else {
            menu.addItem(infoItem("Nothing Playing", font: .menuFont(ofSize: 13)))
        }

        if let zone = playback?.displayName {
            menu.addItem(infoItem(zone, font: .menuFont(ofSize: 11)))
        }

        menu.addItem(.separator())

        let isPlaying = playback?.state == .playing
        add(to: menu, title: isPlaying ? "Pause" : "Play",
            action: #selector(togglePlayPause), enabled: playback?.zoneId != nil)
        add(to: menu, title: "Previous",
            action: #selector(previousTrack), enabled: playback?.zoneId != nil)
        add(to: menu, title: "Next",
            action: #selector(nextTrack), enabled: playback?.zoneId != nil)

        menu.addItem(.separator())
        add(to: menu, title: "Show Main Window", action: #selector(showMainWindow), enabled: true)
        add(to: menu, title: "Settings…", action: #selector(showSettings), enabled: true)

        menu.addItem(.separator())
        add(to: menu, title: "Quit Roonamp", action: #selector(quit), enabled: true)
    }

    private func infoItem(_ title: String, font: NSFont) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        item.isEnabled = false
        return item
    }

    private func add(to menu: NSMenu, title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func togglePlayPause() {
        guard let api = roonAPI, let zoneId = playback?.zoneId else { return }
        Task { await api.playPause(zoneId: zoneId) }
    }

    @objc private func nextTrack() {
        guard let api = roonAPI, let zoneId = playback?.zoneId else { return }
        Task { await api.next(zoneId: zoneId) }
    }

    @objc private func previousTrack() {
        guard let api = roonAPI, let zoneId = playback?.zoneId else { return }
        Task { await api.previous(zoneId: zoneId) }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        WinampWindow.current?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
