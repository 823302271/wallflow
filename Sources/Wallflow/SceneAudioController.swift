import AVFoundation
import Foundation

final class SceneAudioController {
    private let players: [SceneSoundPlayer]

    init(package: ScenePackage, sounds: [SceneSoundObject]) {
        players = sounds.map { SceneSoundPlayer(package: package, model: $0) }
    }

    func setRenderingEnabled(_ enabled: Bool) {
        players.forEach { $0.setRenderingEnabled(enabled) }
    }

    func setMuted(_ muted: Bool) {
        players.forEach { $0.setMuted(muted) }
    }
}

private final class SceneSoundPlayer {
    private let package: ScenePackage
    private let model: SceneSoundObject
    private let cacheDirectory: URL
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var currentIndex = -1
    private var cachedURLs: [Int: URL] = [:]
    private var isRenderingEnabled = true
    private var isMuted = false
    private var shouldResumeAfterPause = false

    init(package: ScenePackage, model: SceneSoundObject) {
        self.package = package
        self.model = model
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallflowAudio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        if !model.startsSilent {
            playNext(initial: true)
        }
    }

    deinit {
        removeEndObserver()
        player?.pause()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard enabled != isRenderingEnabled else { return }
        isRenderingEnabled = enabled
        if enabled {
            if shouldResumeAfterPause {
                player?.play()
            }
            shouldResumeAfterPause = false
        } else {
            shouldResumeAfterPause = player?.timeControlStatus == .playing
            player?.pause()
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.isMuted = muted
    }

    private func playNext(initial: Bool = false) {
        guard isRenderingEnabled else { return }
        let index: Int
        switch model.playbackMode {
        case .loop:
            index = initial ? 0 : (currentIndex + 1) % model.paths.count
        case .random, .single:
            index = Int.random(in: model.paths.indices)
        }

        do {
            let fileURL = try materializeSound(at: index)
            removeEndObserver()
            let item = AVPlayerItem(url: fileURL)
            let player = AVPlayer(playerItem: item)
            player.volume = Float(model.volume)
            player.isMuted = isMuted
            self.player = player
            currentIndex = index
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.playbackFinished()
            }
            player.play()
        } catch {
            NSLog("Wallflow skipped scene sound %@: %@", model.name, error.localizedDescription)
        }
    }

    private func playbackFinished() {
        switch model.playbackMode {
        case .loop, .random:
            playNext()
        case .single:
            removeEndObserver()
            player = nil
        }
    }

    private func materializeSound(at index: Int) throws -> URL {
        if let cached = cachedURLs[index] { return cached }
        let path = model.paths[index]
        let sourceData = try package.data(forPath: path)
        let sourceURL = URL(fileURLWithPath: path)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
        let fileName = "\(index)-\(UUID().uuidString).\(fileExtension)"
        let destination = cacheDirectory.appendingPathComponent(fileName)
        try sourceData.write(to: destination, options: .atomic)
        cachedURLs[index] = destination
        return destination
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
