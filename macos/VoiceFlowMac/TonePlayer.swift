//
//  TonePlayer.swift
//  VoiceFlowMac
//
//  Plays short, professional audio tones when dictation starts and
//  stops. Two quick sine-wave pips — ascending for start, descending
//  for stop. Subtle enough for an office environment, distinct enough
//  to confirm the mic state changed.
//

import AVFoundation

final class TonePlayer {

    static let shared = TonePlayer()

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// Start tone: two quick ascending pips (C5 → E5).
    func playStart() {
        play(frequencies: [523.25, 659.25], durations: [0.06, 0.06])
    }

    /// Stop tone: two quick descending pips (E5 → C5).
    func playStop() {
        play(frequencies: [659.25, 523.25], durations: [0.06, 0.06])
    }

    private func play(frequencies: [Double], durations: [Double]) {
        // Run off main thread to avoid blocking UI.
        DispatchQueue.global(qos: .userInteractive).async {
            let sampleRate: Double = 44100
            var allSamples: [Float] = []

            for (freq, dur) in zip(frequencies, durations) {
                let frameCount = Int(sampleRate * dur)
                // 5ms fade in/out to avoid click
                let fadeFrames = Int(sampleRate * 0.005)

                for i in 0..<frameCount {
                    let t = Double(i) / sampleRate
                    var sample = Float(sin(2.0 * .pi * freq * t))

                    // Amplitude envelope: fade in/out
                    if i < fadeFrames {
                        sample *= Float(i) / Float(fadeFrames)
                    } else if i > frameCount - fadeFrames {
                        sample *= Float(frameCount - i) / Float(fadeFrames)
                    }

                    // Keep it quiet — 20% volume
                    sample *= 0.2

                    allSamples.append(sample)
                }

                // Tiny gap between pips
                let gapFrames = Int(sampleRate * 0.02)
                allSamples.append(contentsOf: [Float](repeating: 0, count: gapFrames))
            }

            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            )!

            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(allSamples.count)
            )!
            buffer.frameLength = AVAudioFrameCount(allSamples.count)

            let channelData = buffer.floatChannelData![0]
            for (i, sample) in allSamples.enumerated() {
                channelData[i] = sample
            }

            // Use a fresh engine each time — the main engine is busy
            // with mic input during recording.
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            // Route to the DEFAULT OUTPUT device (not the input device
            // the mic engine is using).
            engine.connect(player, to: engine.mainMixerNode, format: format)

            do {
                try engine.start()
                player.play()
                player.scheduleBuffer(buffer) {
                    engine.stop()
                }
            } catch {
                // Silently fail — tones are nice-to-have, not critical.
            }
        }
    }
}
