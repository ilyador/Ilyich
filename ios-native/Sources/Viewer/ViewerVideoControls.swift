import AVFoundation
import SwiftUI
import UIKit

/// The video on screen, as the viewer's playback pill sees it. The page that owns the player
/// hands it over while it is the selected page. Only the pill reads this state, so a time tick
/// redraws the pill and nothing else, and the clock stops while the pill is hidden.
@MainActor @Observable final class VideoPlaybackState {
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isScrubbing = false
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var pendingSeek: CMTime?
    @ObservationIgnored private var seeking = false

    /// Shows `player` for the page `owner`, or lets that page go when it has no player to show.
    func show(_ player: AVPlayer?, for owner: String) {
        guard let player else { release(owner); return }
        self.owner = owner
        guard self.player !== player else { return }
        stopTicking()
        self.player = player
        isScrubbing = false; pendingSeek = nil; seeking = false
        if ticking { startTicking() } else { refresh() }
    }

    /// A page that leaves lets go only of its own player, so the page that replaced it keeps the pill.
    func release(_ owner: String) {
        guard self.owner == owner else { return }
        stopTicking()
        self.owner = nil; player = nil
        isScrubbing = false; pendingSeek = nil; seeking = false
        set(\.isPlaying, false); set(\.time, 0); set(\.duration, 0)
    }

    func setTicking(_ on: Bool) {
        guard ticking != on else { return }
        ticking = on
        if on { startTicking() } else { stopTicking() }
    }

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if duration > 0, time >= duration - 0.05 { player.seek(to: .zero) }
            player.play(); set(\.isPlaying, true)
        } else {
            player.pause(); set(\.isPlaying, false)
        }
    }

    /// Dragging pauses the video and chases the finger with one exact seek in flight at a time.
    func scrub(to fraction: Double) {
        guard let player, duration > 0 else { return }
        if !isScrubbing {
            isScrubbing = true
            resumeAfterScrub = player.timeControlStatus != .paused
            player.pause()
        }
        let target = min(max(fraction, 0), 1) * duration
        set(\.time, target)
        pendingSeek = CMTime(seconds: target, preferredTimescale: 600)
        if !seeking { seekToPending() }
    }

    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        if resumeAfterScrub { player?.play(); set(\.isPlaying, true) }
    }

    private func seekToPending() {
        guard let player, let target = pendingSeek else { seeking = false; return }
        pendingSeek = nil; seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.seekToPending() }
        }
    }

    /// Fifteen ticks a second on the main queue, only while the pill shows. The block also runs
    /// whenever playback starts, stops or jumps, which keeps the play button honest.
    private func startTicking() {
        guard let player, timeObserver == nil else { return }
        refresh()
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopTicking() {
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil; observedPlayer = nil
    }

    private func refresh() {
        guard let player else { return }
        set(\.isPlaying, player.timeControlStatus != .paused)
        if let item = player.currentItem, item.duration.isNumeric { set(\.duration, item.duration.seconds) }
        let now = player.currentTime().seconds
        if !isScrubbing, now.isFinite { set(\.time, now) }
    }

    /// Observation announces every write, so unchanged values are not written.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<VideoPlaybackState, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// The video itself, drawn by an AVPlayerLayer with no controls of its own.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) { view.playerLayer.player = nil }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The Photos video pill: play or pause, a bar to drag through the video, and mute. It shows and
/// hides with the viewer's bars. Glass ignores the opacity around it, so the glass is only a
/// background that hiding swaps for `.identity`. The buttons in front leave with a fade, so they
/// also leave the accessibility tree, which a hidden modifier does not reliably update.
struct ViewerVideoControls: View {
    let playback: VideoPlaybackState
    let visible: Bool
    /// Shared with the setting and every video, so muting carries on to the next video, as in Photos.
    @AppStorage("viewerMuteVideo") private var muted = false

    var body: some View {
        ZStack {
            if visible {
                HStack(spacing: 6) {
                    pillButton(playback.isPlaying ? "Pause" : "Play", symbol: playback.isPlaying ? "pause.fill" : "play.fill") { playback.togglePlay() }
                        .disabled(playback.player == nil)
                    VideoScrubber(playback: playback)
                    pillButton(muted ? "Unmute" : "Mute", symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { muted.toggle() }
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
        .background { Color.clear.glassEffect(visible ? .regular : .identity, in: .capsule) }
        .allowsHitTesting(visible)
        .onChange(of: visible, initial: true) { _, visible in playback.setTicking(visible) }
    }

    private func pillButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
    }
}

private struct VideoScrubber: View {
    let playback: VideoPlaybackState

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule().fill(.white.opacity(0.92)).frame(width: width * progress)
            }
            .frame(height: playback.isScrubbing ? 8 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in playback.scrub(to: value.location.x / width) }
                    .onEnded { _ in playback.endScrub() }
            )
        }
        .frame(height: 40)
        .allowsHitTesting(playback.player != nil)
        .animation(.easeOut(duration: 0.15), value: playback.isScrubbing)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.clock(playback.time)) of \(Self.clock(playback.duration))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            playback.scrub(to: progress + step); playback.endScrub()
        }
    }

    private var progress: Double {
        playback.duration > 0 ? min(1, max(0, playback.time / playback.duration)) : 0
    }

    private static func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds.isFinite ? max(0, seconds) : 0).formatted(.time(pattern: .minuteSecond))
    }
}
