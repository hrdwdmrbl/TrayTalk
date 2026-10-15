//
//  SpeechManager.swift
//  Smooth Talker
//
//  Created by Sem Visscher on 24/12/2024.
//

import Foundation
import AVFAudio
import AVFoundation
import Cocoa
#if DEBUG
import OSLog
#endif

class SpeechManager {
    static let shared = SpeechManager()
    
    private var audioPlayer = AudioPlayer()
    private var audioData: Data?
    private var activeSpeechID = UUID()
    var appDelegate: AppDelegate?
    
    private init() {}
    
    func speak(_ text: String) {
        Task { @MainActor in
            self.speakFromMainActor(text)
        }
    }

    @MainActor
    private func speakFromMainActor(_ text: String) {
        let speechID = UUID()
        activeSpeechID = speechID
        let chunks = TextChunker.chunks(text)
        
        DispatchQueue.main.async {
            self.appDelegate?.setTrayLoading(true)
        }
        
        let voiceName = Preferences.shared.voiceName
        let speed = Preferences.shared.speakingSpeed
        PlaybackDiagnostics.logSpeechStart(
            speechID: speechID,
            chunkCount: chunks.count,
            voiceName: voiceName,
            speed: speed,
            textLength: text.count
        )

        audioPlayer.stop(reason: "new speech session \(speechID.uuidString)")
        TextToSpeechClient.cancelAudioRequests(except: speechID)
        
        if voiceName.isEmpty {
            DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
            return
        }
        
        if VoiceCategory(for: voiceName).requiresPremiumUnlock &&
            !PurchaseManager.shared.hasPremiumVoices &&
            !Preferences.shared.isAppReviewDemoModeEnabled {
            DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
            return
        }
        
        if chunks.isEmpty {
            DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
            return
        }
        
        TextToSpeechClient.getInstance { apiResult in
            guard self.activeSpeechID == speechID else { return }

            guard case .success(let api) = apiResult else {
                DispatchQueue.main.async { self.appDelegate?.setTrayLoading(false) }
                return
            }

            api.cancelAudioRequests(excluding: speechID)
            
            var audioByChunkIndex: [Int: Data] = [:]
            var nextChunkToPlay = 0
            var failedChunkIndex: Int?
            var didStartPlayback = false
            
            func drainReadyChunks() {
                while let audio = audioByChunkIndex[nextChunkToPlay] {
                    if let failedChunkIndex = failedChunkIndex,
                       nextChunkToPlay >= failedChunkIndex {
                        audioByChunkIndex[nextChunkToPlay] = nil
                        return
                    }
                    
                    audioByChunkIndex[nextChunkToPlay] = nil
                    let diagnosticContext = PlaybackDiagnosticContext(
                        speechID: speechID,
                        chunkIndex: nextChunkToPlay,
                        chunkCount: chunks.count,
                        voiceName: voiceName,
                        speed: Preferences.shared.speakingSpeed
                    )
                    
                    if didStartPlayback {
                        self.audioPlayer.enqueue(data: audio, diagnosticContext: diagnosticContext)
                    } else {
                        self.audioData = audio
                        self.audioPlayer.play(data: audio, diagnosticContext: diagnosticContext)
                        didStartPlayback = true
                        
                        DispatchQueue.main.async {
                            self.appDelegate?.setTrayLoading(false)
                        }
                    }
                    
                    nextChunkToPlay += 1
                }
            }
            
            func markChunkFailed(_ index: Int, error _: Error) {
                if let existingFailedChunkIndex = failedChunkIndex {
                    failedChunkIndex = min(existingFailedChunkIndex, index)
                } else {
                    failedChunkIndex = index
                }
                
                let firstFailedChunkIndex = failedChunkIndex ?? index
                audioByChunkIndex = audioByChunkIndex.filter { $0.key < firstFailedChunkIndex }

                if index == 0 && !didStartPlayback {
                    DispatchQueue.main.async {
                        self.appDelegate?.setTrayLoading(false)
                    }
                } else {
                    drainReadyChunks()
                }
            }
            
            for (index, chunk) in chunks.enumerated() {
                let chunkLabel = "chunk-\(index + 1)"
                
                api.getAudio(text: chunk,
                             language: Preferences.shared.language,
                             voiceName: voiceName,
                             speed: Preferences.shared.speakingSpeed,
                             speechID: speechID,
                             chunkLabel: chunkLabel
                ) { result in
                    guard self.activeSpeechID == speechID else { return }
                    
                    switch result {
                    case .success(let data):
                        if let failedChunkIndex = failedChunkIndex,
                           index >= failedChunkIndex {
                            return
                        }
                        
                        audioByChunkIndex[index] = data
                        drainReadyChunks()
                    case .failure(let error):
                        markChunkFailed(index, error: error)
                    }
                }
            }
        }
    }
}

private struct PlaybackDiagnosticContext {
    let speechID: UUID
    let chunkIndex: Int
    let chunkCount: Int
    let voiceName: String
    let speed: Double

    var publicDescription: String {
        "session=\(speechID.uuidString) chunk=\(chunkIndex + 1)/\(chunkCount) voice=\(voiceName) speed=\(SpeakingSpeed.formatted(speed))"
    }
}

private enum PlaybackDiagnostics {
    #if DEBUG
    private static let logger = Logger(
        subsystem: "com.cyberofficeindustries.smoothtalker",
        category: "PlaybackDiagnostics"
    )
    #endif

    static func logSpeechStart(speechID: UUID, chunkCount: Int, voiceName: String, speed: Double, textLength: Int) {
        #if DEBUG
        logger.notice(
            "speech start session=\(speechID.uuidString, privacy: .public) chunks=\(chunkCount, privacy: .public) voice=\(voiceName, privacy: .public) speed=\(SpeakingSpeed.formatted(speed), privacy: .public) textLength=\(textLength, privacy: .public)"
        )
        #endif
    }

    static func log(_ message: String, context: PlaybackDiagnosticContext? = nil) {
        #if DEBUG
        if let context {
            logger.notice("\(message, privacy: .public); \(context.publicDescription, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
        #endif
    }

    static func audioHash(_ data: Data) -> String {
        #if DEBUG
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        return String(format: "%016llx", hash)
        #else
        return ""
        #endif
    }

    static func saveSourceAudio(_ data: Data, context: PlaybackDiagnosticContext, hash: String) -> URL? {
        #if DEBUG
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmoothTalkerPlaybackDiagnostics", isDirectory: true)
            .appendingPathComponent(context.speechID.uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory
                .appendingPathComponent("chunk-\(context.chunkIndex + 1)-\(hash)")
                .appendingPathExtension("mp3")
            try data.write(to: fileURL)
            return fileURL
        } catch {
            log("failed to save source audio error=\(error.localizedDescription)", context: context)
            return nil
        }
        #else
        return nil
        #endif
    }
}

private struct TextChunker {
    private static let chunkTargets = [125, 500, 800]
    private static let defaultChunkTarget = 1000
    
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        while !remaining.isEmpty {
            let target = targetLength(forChunkAt: chunks.count)
            
            guard remaining.count > target,
                  let breakIndex = firstBreakIndex(in: remaining, after: target) else {
                chunks.append(remaining)
                break
            }
            
            let chunk = String(remaining[..<breakIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            
            remaining = String(remaining[breakIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return chunks
    }
    
    private static func targetLength(forChunkAt index: Int) -> Int {
        guard index < chunkTargets.count else {
            return defaultChunkTarget
        }
        
        return chunkTargets[index]
    }
    
    private static func firstBreakIndex(in text: String, after target: Int) -> String.Index? {
        var index = text.index(text.startIndex, offsetBy: target)
        
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            
            if character == "\n" || character == ";" || character == "?" || character == "!" {
                return nextIndex
            }
            
            if character == "." && nextIndex < text.endIndex && text[nextIndex].isWhitespace {
                return nextIndex
            }
            
            index = nextIndex
        }
        
        return nil
    }
}


class AudioPlayer: ObservableObject {
    private var player: AVQueuePlayer?
    private var tempURLs: [URL] = []
    private var playbackGeneration = 0
    private var readinessObserver: NSKeyValueObservation?

    fileprivate func play(data: Data, diagnosticContext: PlaybackDiagnosticContext? = nil) {
        stop(reason: "replace current audio before first chunk")
        enqueue(data: data, diagnosticContext: diagnosticContext, waitForReadinessBeforeStart: true)
    }

    fileprivate func enqueue(data: Data, diagnosticContext: PlaybackDiagnosticContext? = nil) {
        enqueue(data: data, diagnosticContext: diagnosticContext, waitForReadinessBeforeStart: false)
    }

    private func enqueue(data: Data, diagnosticContext: PlaybackDiagnosticContext?, waitForReadinessBeforeStart: Bool) {
        do {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp3")
            try data.write(to: fileURL)
            tempURLs.append(fileURL)

            let hash = PlaybackDiagnostics.audioHash(data)
            let diagnosticSourceURL = diagnosticContext.flatMap {
                PlaybackDiagnostics.saveSourceAudio(data, context: $0, hash: hash)
            }
            PlaybackDiagnostics.log(
                "enqueue sourceBytes=\(data.count) sourceHash=\(hash) sourcePath=\(diagnosticSourceURL?.path ?? "nil") tempPath=\(fileURL.path)",
                context: diagnosticContext
            )

            let playerItem = AVPlayerItem(url: fileURL)
            if let player = player {
                player.insert(playerItem, after: nil)
                PlaybackDiagnostics.log("inserted queued player item", context: diagnosticContext)

                if player.currentItem === playerItem && (player.timeControlStatus != .playing || player.rate == 0) {
                    startPlayback(item: playerItem, diagnosticContext: diagnosticContext)
                } else {
                    PlaybackDiagnostics.log("queued item inserted behind current item; no restart", context: diagnosticContext)
                }
            } else {
                player = AVQueuePlayer(items: [playerItem])
                player?.automaticallyWaitsToMinimizeStalling = false
                PlaybackDiagnostics.log("created queue player automaticallyWaitsToMinimizeStalling=false", context: diagnosticContext)

                if waitForReadinessBeforeStart {
                    startFirstItemWhenReady(item: playerItem, diagnosticContext: diagnosticContext)
                } else {
                    startPlayback(item: playerItem, diagnosticContext: diagnosticContext)
                }
            }
        } catch {
            PlaybackDiagnostics.log("enqueue failed error=\(error.localizedDescription)", context: diagnosticContext)
        }
    }

    func stop(reason: String = "stop requested") {
        playbackGeneration += 1
        readinessObserver?.invalidate()
        readinessObserver = nil
        PlaybackDiagnostics.log("stop reason=\(reason)")
        if let player = player {
            PlaybackDiagnostics.log("stop before cleanup \(snapshotDescription(item: player.currentItem))")
            player.cancelPendingPrerolls()
            player.pause() // Pause playback
            player.removeAllItems()
        }
        player = nil

        for tempURL in tempURLs {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
            }
        }
        tempURLs.removeAll()
    }

    private func startFirstItemWhenReady(item: AVPlayerItem, diagnosticContext: PlaybackDiagnosticContext?) {
        playbackGeneration += 1
        let generation = playbackGeneration
        let rate = Float(Preferences.shared.speakingSpeed)

        guard let player else { return }

        player.defaultRate = rate
        logSnapshot("waiting for first item readiness rate=\(rate)", item: item, diagnosticContext: diagnosticContext)
        scheduleReadinessSnapshots(item: item, generation: generation, diagnosticContext: diagnosticContext)

        if item.status == .readyToPlay {
            readinessObserver = nil
            prerollFirstItem(item: item, player: player, rate: rate, generation: generation, diagnosticContext: diagnosticContext)
            return
        }

        if item.status == .failed {
            PlaybackDiagnostics.log("first item failed before playback error=\(item.error?.localizedDescription ?? "nil")", context: diagnosticContext)
            return
        }

        readinessObserver?.invalidate()
        readinessObserver = item.observe(\.status, options: [.new]) { [weak self, weak player, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self,
                      let player,
                      let item else {
                    return
                }

                self.handleFirstItemStatusChange(item: item, player: player, rate: rate, generation: generation, diagnosticContext: diagnosticContext)
            }
        }
    }

    private func handleFirstItemStatusChange(item: AVPlayerItem, player: AVQueuePlayer, rate: Float, generation: Int, diagnosticContext: PlaybackDiagnosticContext?) {
        guard playbackGeneration == generation,
              self.player === player,
              player.currentItem === item else {
            PlaybackDiagnostics.log("ignored stale first item readiness callback", context: diagnosticContext)
            return
        }

        logSnapshot("first item readiness changed", item: item, diagnosticContext: diagnosticContext)

        switch item.status {
        case .readyToPlay:
            readinessObserver?.invalidate()
            readinessObserver = nil
            prerollFirstItem(item: item, player: player, rate: rate, generation: generation, diagnosticContext: diagnosticContext)
        case .failed:
            readinessObserver?.invalidate()
            readinessObserver = nil
            PlaybackDiagnostics.log("first item failed before playback error=\(item.error?.localizedDescription ?? "nil")", context: diagnosticContext)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func prerollFirstItem(item: AVPlayerItem, player: AVQueuePlayer, rate: Float, generation: Int, diagnosticContext: PlaybackDiagnosticContext?) {
        guard playbackGeneration == generation,
              self.player === player,
              player.currentItem === item else {
            PlaybackDiagnostics.log("skipped stale first item preroll", context: diagnosticContext)
            return
        }

        logSnapshot("before first item preroll rate=\(rate)", item: item, diagnosticContext: diagnosticContext)

        player.preroll(atRate: rate) { [weak self, weak player, weak item] finished in
            DispatchQueue.main.async {
                guard let self,
                      let player,
                      let item else {
                    return
                }

                guard self.playbackGeneration == generation,
                      self.player === player,
                      player.currentItem === item else {
                    PlaybackDiagnostics.log("ignored stale first item preroll completion finished=\(finished)", context: diagnosticContext)
                    return
                }

                self.logSnapshot("after first item preroll finished=\(finished) rate=\(rate)", item: item, diagnosticContext: diagnosticContext)
                if !finished {
                    PlaybackDiagnostics.log("first item preroll did not finish; starting ready item", context: diagnosticContext)
                }

                self.startPlayback(item: item, rate: rate, generation: generation, diagnosticContext: diagnosticContext)
            }
        }
    }
    
    private func startPlayback(item: AVPlayerItem, diagnosticContext: PlaybackDiagnosticContext?) {
        playbackGeneration += 1
        let generation = playbackGeneration
        let rate = Float(Preferences.shared.speakingSpeed)
        startPlayback(item: item, rate: rate, generation: generation, diagnosticContext: diagnosticContext)
    }

    private func startPlayback(item: AVPlayerItem, rate: Float, generation: Int, diagnosticContext: PlaybackDiagnosticContext?) {
        guard let player,
              playbackGeneration == generation,
              player.currentItem === item else {
            PlaybackDiagnostics.log("skipped stale playImmediately", context: diagnosticContext)
            return
        }

        logSnapshot("before playImmediately rate=\(rate)", item: item, diagnosticContext: diagnosticContext)
        player.defaultRate = rate
        player.playImmediately(atRate: rate)
        logSnapshot("after playImmediately rate=\(rate)", item: item, diagnosticContext: diagnosticContext)

        for delay in [0.05, 0.15, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak item] in
                guard let self,
                      self.playbackGeneration == generation,
                      let item else {
                    return
                }

                self.logSnapshot("+\(delay)s after playImmediately", item: item, diagnosticContext: diagnosticContext)
            }
        }
    }

    private func scheduleReadinessSnapshots(item: AVPlayerItem, generation: Int, diagnosticContext: PlaybackDiagnosticContext?) {
        for delay in [0.05, 0.15, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak item] in
                guard let self,
                      self.playbackGeneration == generation,
                      let item else {
                    return
                }

                self.logSnapshot("+\(delay)s while waiting for first item readiness", item: item, diagnosticContext: diagnosticContext)
            }
        }
    }

    private func logSnapshot(_ label: String, item: AVPlayerItem?, diagnosticContext: PlaybackDiagnosticContext?) {
        PlaybackDiagnostics.log("\(label) \(snapshotDescription(item: item))", context: diagnosticContext)
    }

    private func snapshotDescription(item: AVPlayerItem?) -> String {
        let playerStatus = player.map { playerStatusDescription($0.status) } ?? "nil"
        let timeControlStatus = player.map { timeControlStatusDescription($0.timeControlStatus) } ?? "nil"
        let playerRate = player?.rate ?? 0
        let defaultRate = player?.defaultRate ?? 0
        let currentTime = item.map { timeDescription($0.currentTime()) } ?? "nil"
        let duration = item.map { timeDescription($0.duration) } ?? "nil"
        let itemStatus = item.map { itemStatusDescription($0.status) } ?? "nil"
        let reasonForWaiting = player?.reasonForWaitingToPlay?.rawValue ?? "nil"

        return "playerStatus=\(playerStatus) itemStatus=\(itemStatus) timeControlStatus=\(timeControlStatus) reasonForWaiting=\(reasonForWaiting) rate=\(playerRate) defaultRate=\(defaultRate) currentTime=\(currentTime) duration=\(duration)"
    }

    private func itemStatusDescription(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknownDefault(\(status.rawValue))"
        }
    }

    private func playerStatusDescription(_ status: AVPlayer.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknownDefault(\(status.rawValue))"
        }
    }

    private func timeControlStatusDescription(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused:
            return "paused"
        case .waitingToPlayAtSpecifiedRate:
            return "waitingToPlayAtSpecifiedRate"
        case .playing:
            return "playing"
        @unknown default:
            return "unknownDefault(\(status.rawValue))"
        }
    }

    private func timeDescription(_ time: CMTime) -> String {
        guard time.isNumeric else {
            if time == .indefinite { return "indefinite" }
            if time == .positiveInfinity { return "positiveInfinity" }
            if time == .negativeInfinity { return "negativeInfinity" }
            return "invalid"
        }

        return String(format: "%.4f", CMTimeGetSeconds(time))
    }
}
