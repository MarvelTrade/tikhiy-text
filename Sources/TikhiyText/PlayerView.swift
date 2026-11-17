import SwiftUI
import AVKit

struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

@MainActor
final class PlayerController: ObservableObject {
    @Published var player = AVPlayer()
    @Published var currentTime = 0.0
    @Published var duration = 0.0
    @Published var isPlaying = false
    @Published var playbackRate: Float = 1.0
    private var currentPath = ""
    private var timeObserver: Any?

    func load(_ url: URL) {
        guard currentPath != url.path else { return }
        currentPath = url.path
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0) }
        }
        Task {
            if let value = try? await item.asset.load(.duration), value.seconds.isFinite {
                duration = max(0, value.seconds)
            }
        }
    }

    func seek(milliseconds: Int) {
        seek(seconds: Double(milliseconds) / 1000)
        player.play()
        player.rate = playbackRate
        isPlaying = true
    }

    func seek(seconds: Double) {
        let target = min(max(seconds, 0), max(duration, seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            player.rate = playbackRate
            isPlaying = true
        }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
    }

    func skip(_ seconds: Double) {
        seek(seconds: currentTime + seconds)
    }
}
