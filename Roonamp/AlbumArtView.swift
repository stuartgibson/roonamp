//
//  AlbumArtView.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import SwiftUI

struct AlbumArtView: View {
    @EnvironmentObject var playback: PlaybackState
    @State private var isHovering = false
    @AppStorage("albumArtShowTrackInfo") private var showTrackInfo = true
    @State private var refreshID = UUID()
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Album Art Background
            Color.black
                .ignoresSafeArea()
            
            // Album Art Content
            if let nowPlaying = playback.nowPlaying,
               let imageUrl = nowPlaying.imageUrl,
               let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    Group {
                        switch phase {
                        case .empty:
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        case .failure:
                            Image(systemName: "opticaldisc.fill")
                                .font(.system(size: 80))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .id(refreshID)
            } else {
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Track Info Overlay (bottom)
            if let nowPlaying = playback.nowPlaying {
                VStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlaying.artist)
                            .font(.system(size: 13, weight: .semibold))
                        Text(nowPlaying.album)
                            .font(.system(size: 12))
                            .opacity(0.8)
                        Text(nowPlaying.title)
                            .font(.system(size: 12))
                            .opacity(0.8)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .allowsHitTesting(false)
                .opacity(showTrackInfo ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showTrackInfo)
            }

            // Traffic lights overlay (hover only)
            if isHovering {
                HStack(spacing: 8) {
                    Button {
                        #if os(macOS)
                        NSApp.windows.first(where: { $0.title == "Album Art" })?.close()
                        #endif
                    } label: {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                            .overlay {
                                Image(systemName: "xmark")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundColor(.black.opacity(0.5))
                            }
                    }
                    .buttonStyle(.plain)

                    Button {
                        #if os(macOS)
                        NSApp.windows.first(where: { $0.title == "Album Art" })?.miniaturize(nil)
                        #endif
                    } label: {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 12, height: 12)
                            .overlay {
                                Image(systemName: "minus")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundColor(.black.opacity(0.5))
                            }
                    }
                    .buttonStyle(.plain)

                    Button {
                        #if os(macOS)
                        NSApp.windows.first(where: { $0.title == "Album Art" })?.zoom(nil)
                        #endif
                    } label: {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 12, height: 12)
                            .overlay {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 5, weight: .bold))
                                    .foregroundColor(.black.opacity(0.5))
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .aspectRatio(1.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .winampWindowDrag(onClick: { showTrackInfo.toggle() })
        .background(AlbumArtWindowAccessor())
        .onAppear {
            // Force AsyncImage to reload when window appears
            refreshID = UUID()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

#if os(macOS)
import AppKit

class AlbumArtWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minDimension: CGFloat = 200
        let side = max(frameSize.width, minDimension)
        return NSSize(width: side, height: side)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        UserDefaults.standard.set(window.frame.width, forKey: "albumArtWidth")
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "isAlbumArtVisible")
        NotificationCenter.default.post(name: .albumArtVisibilityChanged, object: false)
    }
}

/// NSView that provides resize cursors at the edges of a borderless window
class AlbumArtResizeCursorView: NSView {
    private let edgeInset: CGFloat = 6

    override func resetCursorRects() {
        let b = bounds
        let e = edgeInset

        // Corners (diagonal resize)
        addCursorRect(NSRect(x: 0, y: 0, width: e, height: e), cursor: .crosshair)
        addCursorRect(NSRect(x: b.maxX - e, y: 0, width: e, height: e), cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: b.maxY - e, width: e, height: e), cursor: .crosshair)
        addCursorRect(NSRect(x: b.maxX - e, y: b.maxY - e, width: e, height: e), cursor: .crosshair)

        // Edges (resize arrows)
        addCursorRect(NSRect(x: e, y: 0, width: b.width - 2 * e, height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: e, y: b.maxY - e, width: b.width - 2 * e, height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: e, width: e, height: b.height - 2 * e), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - e, y: e, width: e, height: b.height - 2 * e), cursor: .resizeLeftRight)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        window?.invalidateCursorRects(for: self)
    }
}

struct AlbumArtWindowAccessor: NSViewRepresentable {
    func makeCoordinator() -> AlbumArtWindowDelegate {
        AlbumArtWindowDelegate()
    }

    func makeNSView(context: Context) -> AlbumArtResizeCursorView {
        let view = AlbumArtResizeCursorView()
        DispatchQueue.main.async {
            if let window = view.window {
                WinampWindow.albumArt = window

                // Completely borderless window
                window.styleMask = [.borderless, .resizable]

                // Transparent background
                window.isOpaque = false
                window.backgroundColor = .clear

                // Round the corners
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.cornerRadius = 12
                window.contentView?.layer?.masksToBounds = true

                // Make window movable by dragging content
                window.isMovableByWindowBackground = true

                // Enable shadow
                window.hasShadow = true

                // Maintain square aspect ratio with minimum size
                window.aspectRatio = NSSize(width: 1, height: 1)
                window.minSize = NSSize(width: 200, height: 200)
                window.delegate = context.coordinator

                // Restore saved size (default 400×400)
                let savedWidth = UserDefaults.standard.double(forKey: "albumArtWidth")
                let side = savedWidth >= 200 ? savedWidth : 400
                let origin = window.frame.origin
                window.setFrame(NSRect(x: origin.x, y: origin.y, width: side, height: side), display: true)

                let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
                window.level = alwaysOnTop ? .floating : .normal

                NotificationCenter.default.addObserver(
                    forName: .alwaysOnTopChanged,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let alwaysOnTop = notification.object as? Bool {
                        window.level = alwaysOnTop ? .floating : .normal
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: AlbumArtResizeCursorView, context: Context) {}
}
#endif

#Preview {
    let api = RoonAPI(
        appInfo: RoonAppInfo(
            extensionId: "com.yourcompany.roonamp",
            displayName: "Roonamp",
            displayVersion: "1.0.0",
            publisher: "Your Name",
            email: "your.email@example.com"
        )
    )
    AlbumArtView()
        .environmentObject(api.playback)
        .frame(width: 400, height: 400)
}
