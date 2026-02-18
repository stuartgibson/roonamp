//
//  ContentView.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var roonAPI: RoonAPI
    @EnvironmentObject var playback: PlaybackState
    @State private var isConnecting = false
    @Binding var showAlbumArt: Bool
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        ZStack {
            // Background with rounded corners
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            
            // Content
            Group {
                if roonAPI.isConnected {
                    // Connected view with transport controls
                    connectedView
                        .onAppear {
                            // Clear connecting state when successfully connected
                            isConnecting = false
                        }
                } else if isConnecting {
                    // Connecting state
                    connectingView
                } else {
                    // Discovery and connection view (only if connection failed)
                    discoveryView
                }
            }
        }
        .background(WindowAccessor(isConnected: roonAPI.isConnected))
        .onAppear {
            // Auto-connect on launch
            if !roonAPI.isConnected && !isConnecting {
                connectToRoon()
            }
        }
    }
    
    private var connectingView: some View {
        VStack(spacing: 15) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            
            Text("Connecting to Roon...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            ProgressView()
                .scaleEffect(0.8)
            
            if let error = roonAPI.errorMessage {
                VStack(spacing: 10) {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    
                    Button("Retry") {
                        connectToRoon()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal)
            }
        }
        .frame(width: 350)
        .padding(.vertical, 30)
        .fixedSize()
    }
    
    private var discoveryView: some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            
            Text("Connection Failed")
                .font(.headline)
            
            if let error = roonAPI.errorMessage {
                Text(error)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            
            Button {
                connectToRoon()
            } label: {
                Label("Retry Connection", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(width: 350)
        .padding(.vertical, 30)
        .fixedSize()
    }
    
    private var connectedView: some View {
        VStack(spacing: 15) {
            // Track Info
            if let nowPlaying = playback.nowPlaying {
                VStack(spacing: 3) {
                    Text(nowPlaying.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(nowPlaying.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(nowPlaying.album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.horizontal)
            } else {
                VStack(spacing: 3) {
                    Text("No music playing")
                        .foregroundStyle(.secondary)

                    if let zoneName = playback.displayName {
                        Text(zoneName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            // Horizontal Controls + Album Art
            HStack(spacing: 20) {
                // Transport Controls
                HStack(spacing: 30) {
                    Button {
                        guard let zoneId = playback.zoneId else { return }
                        Task {
                            await roonAPI.previous(zoneId: zoneId)
                        }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                    }
                    .disabled(playback.zoneId == nil)

                    Button {
                        guard let zoneId = playback.zoneId else { return }
                        Task {
                            await roonAPI.playPause(zoneId: zoneId)
                        }
                    } label: {
                        let isPlaying = playback.state == .playing
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 60))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(playback.zoneId == nil)
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: playback.state)

                    Button {
                        guard let zoneId = playback.zoneId else { return }
                        Task {
                            await roonAPI.next(zoneId: zoneId)
                        }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                    .disabled(playback.zoneId == nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                
                // Small Album Art (clickable)
                if let nowPlaying = playback.nowPlaying {
                    Button {
                        if showAlbumArt {
                            // Close the window
                            #if os(macOS)
                            NSApp.windows.first(where: { $0.title == "Album Art" })?.close()
                            #endif
                        } else {
                            // Open new window
                            openWindow(id: "album-art", value: true)
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.2))
                            .aspectRatio(1, contentMode: .fit)
                            .frame(width: 60, height: 60)
                            .overlay {
                                if let imageUrl = nowPlaying.imageUrl,
                                   let url = URL(string: imageUrl) {
                                    AsyncImage(url: url) { phase in
                                        Group {
                                            switch phase {
                                            case .empty:
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                            case .success(let image):
                                                image
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                            case .failure:
                                                Image(systemName: "photo")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(.secondary)
                                            @unknown default:
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(showAlbumArt ? Color.accentColor : Color.clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(showAlbumArt ? "Hide Album Art" : "Show Album Art")
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 12)
        .padding(.bottom, 15)
        .fixedSize()
    }
    
    
    private func connectToRoon() {
        isConnecting = true
        
        print("🔌 Starting Roon Core discovery")
        
        // Use the existing RoonAPI instance
        roonAPI.connect()
        
        // Reset connecting state after a longer delay to give time for connection
        // If still not connected after 10 seconds, show the manual connection screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !roonAPI.isConnected {
                isConnecting = false
            }
        }
    }
}

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
    ContentView(showAlbumArt: .constant(false))
        .environmentObject(api)
        .environmentObject(api.playback)
}

#if os(macOS)
import AppKit

struct WindowAccessor: NSViewRepresentable {
    let isConnected: Bool
    @EnvironmentObject var roonAPI: RoonAPI
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                self.configureWindow(window)
                
                // Listen for alwaysOnTop changes
                NotificationCenter.default.addObserver(
                    forName: .alwaysOnTopChanged,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let alwaysOnTop = notification.object as? Bool {
                        window.level = alwaysOnTop ? .floating : .normal
                        print("🪟 Window level changed to: \(alwaysOnTop ? "floating" : "normal")")
                    }
                }
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Update window when connection state changes
        if let window = nsView.window {
            DispatchQueue.main.async {
                self.configureWindow(window)
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        // Remove title bar
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        
        // Make background transparent for rounded corners
        window.isOpaque = false
        window.backgroundColor = .clear
        
        // Hide traffic lights (close, minimize, maximize buttons)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        
        // Make window movable by dragging anywhere
        window.isMovableByWindowBackground = true
        
        // Add a nice shadow
        window.hasShadow = true
        
        // Make window non-resizable
        window.styleMask.remove(.resizable)
        
        // Set fixed size based on content
        let contentSize: NSSize
        if isConnected {
            // Compact player size
            contentSize = NSSize(width: 420, height: 180)
        } else {
            // Connecting/error size
            contentSize = NSSize(width: 370, height: 200)
        }
        
        window.setContentSize(contentSize)
        window.minSize = contentSize
        window.maxSize = contentSize
        
        // Set initial window level based on preference
        let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        window.level = alwaysOnTop ? .floating : .normal
    }
}
#endif


