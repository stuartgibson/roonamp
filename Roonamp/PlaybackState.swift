//
//  PlaybackState.swift
//  Roonamp
//
//  Focused ObservableObject for playback display data.
//  Views that only need playback info observe this instead of RoonAPI,
//  avoiding unnecessary re-evaluation when unrelated properties change.
//
//  Owns all seek position tracking: server updates, user-initiated seeks,
//  and interpolation between server ticks. Consumers read currentSeekPosition
//  and subscribe to currentSeekPositionSubject for display updates.
//

import Foundation
import Combine

@MainActor
class PlaybackState: ObservableObject {
    @Published var state: RoonZone.PlaybackState? {
        didSet {
            guard state != oldValue else { return }
            if state == .playing {
                startInterpolation()
            } else {
                stopInterpolation()
            }
        }
    }
    @Published var nowPlaying: NowPlaying?
    @Published var zoneId: String?
    @Published var displayName: String?

    /// The interpolated seek position for display. NOT @Published to avoid
    /// re-evaluating views that don't need it (AlbumArtView, ContentView).
    /// Views that display seek position subscribe via `currentSeekPositionSubject`.
    private(set) var currentSeekPosition: Int = 0 {
        didSet {
            if currentSeekPosition != oldValue {
                currentSeekPositionSubject.send(currentSeekPosition)
            }
        }
    }
    let currentSeekPositionSubject = PassthroughSubject<Int, Never>()

    /// Raw server seek position, set by RoonAPI.
    /// Every update refreshes the interpolation base time.
    var seekPosition: Int = 0 {
        didSet {
            handleServerSeekUpdate(seekPosition)
        }
    }

    // Interpolation state
    private var lastUpdateTime: Date = Date()
    private var localSeekPosition: Int?
    private var interpolationTimer: Timer?

    /// Called when the user initiates a seek (drag, windowshade bar, etc).
    func handleUserSeek(_ newPos: Int) {
        localSeekPosition = newPos
        currentSeekPosition = newPos
        lastUpdateTime = Date()
    }

    // MARK: - Private

    private func handleServerSeekUpdate(_ newPos: Int) {
        if let localSeek = localSeekPosition {
            // User recently seeked — wait for server to confirm (within 3s)
            if abs(newPos - localSeek) <= 3 {
                localSeekPosition = nil
                currentSeekPosition = newPos
                lastUpdateTime = Date()
            }
        } else {
            currentSeekPosition = newPos
            lastUpdateTime = Date()
        }
    }

    private func startInterpolation() {
        stopInterpolation()
        interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.interpolateTick()
            }
        }
    }

    private func stopInterpolation() {
        interpolationTimer?.invalidate()
        interpolationTimer = nil
    }

    private func interpolateTick() {
        guard state == .playing else { return }
        let elapsed = Date().timeIntervalSince(lastUpdateTime)
        if let localBase = localSeekPosition {
            currentSeekPosition = localBase + Int(elapsed)
        } else {
            currentSeekPosition = seekPosition + Int(elapsed)
        }
    }
}
