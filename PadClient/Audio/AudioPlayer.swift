import AVFoundation
import Foundation
import StreamCore

/// Plays 48 kHz stereo Int16 PCM chunks as they arrive. No jitter buffer:
/// a late packet is a brief gap, which is the trade for low latency.
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: StreamService.audioSampleRate, channels: AVAudioChannelCount(StreamService.audioChannels))!
    private let queue = DispatchQueue(label: "macstream.audio.play", qos: .userInteractive)
    private var started = false

    var isMuted = false {
        didSet { player.volume = isMuted ? 0 : 1 }
    }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setPreferredIOBufferDuration(0.005)
                try session.setActive(true)
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                try engine.start()
                player.play()
                started = true
            } catch {
                print("[MacStream] audio start failed: \(error)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard started else { return }
            player.stop()
            engine.stop()
            started = false
        }
    }

    /// Interleaved Int16 stereo → the engine's Float32 planar format.
    func play(_ pcm: Data) {
        queue.async { [self] in
            guard started else { return }
            let frameCount = pcm.count / 4
            guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channels = buffer.floatChannelData else { return }
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for frame in 0..<frameCount {
                    channels[0][frame] = Float(samples[frame * 2]) / 32767
                    channels[1][frame] = Float(samples[frame * 2 + 1]) / 32767
                }
            }
            player.scheduleBuffer(buffer)
        }
    }
}
