@preconcurrency import AVFoundation
import Foundation

@MainActor
protocol AudioPlaybackService: AnyObject {
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }

    func play(url: URL) throws
    func seek(toProgress progress: Double)
    func stop()
}

@MainActor
final class RealAudioPlaybackService: NSObject, AudioPlaybackService, @preconcurrency AVAudioPlayerDelegate {
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onFinish: (() -> Void)?

    private var player: AVAudioPlayer?
    // Deinitializers are nonisolated. The timer is otherwise created, mutated,
    // and fired exclusively on the main run loop, and cannot race once `self`
    // has begun deinitializing.
    nonisolated(unsafe) private var progressTimer: Timer?

    func play(url: URL) throws {
        stop(notify: false)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw AudioPlaybackError.couldNotStart
        }

        self.player = player
        publishProgress()
        installTimer()
    }

    func stop() {
        stop(notify: false)
    }

    func seek(toProgress progress: Double) {
        guard let player, progress.isFinite else { return }

        let clampedProgress = min(max(progress, 0), 1)
        player.currentTime = player.duration * clampedProgress
        publishProgress()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        stop(notify: true)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        stop(notify: true)
    }

    private func installTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.publishProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func publishProgress() {
        guard let player else { return }
        onProgress?(player.currentTime, player.duration)
    }

    private func stop(notify: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        onProgress?(0, 0)
        if notify {
            onFinish?()
        }
    }

    deinit {
        progressTimer?.invalidate()
    }
}

enum AudioPlaybackError: LocalizedError {
    case fileMissing
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "Аудиофайл этой записи не найден."
        case .couldNotStart:
            return "Не удалось начать воспроизведение аудио."
        }
    }
}
