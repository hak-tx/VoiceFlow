//
//  TonePlayer.swift
//  VoiceFlowMac
//
//  Plays short, professional audio tones when dictation starts/stops.
//  Uses NSSound with system sounds to avoid conflicting with the
//  AVAudioEngine used for mic capture.
//

import AppKit

final class TonePlayer {
    static let shared = TonePlayer()

    /// Start tone — system "Tink" sound (short, subtle tap).
    func playStart() {
        NSSound(named: "Tink")?.play()
    }

    /// Stop tone — system "Pop" sound (slightly lower, distinct).
    func playStop() {
        NSSound(named: "Pop")?.play()
    }
}
