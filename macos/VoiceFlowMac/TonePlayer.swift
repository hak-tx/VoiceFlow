//
//  TonePlayer.swift
//  VoiceFlowMac
//

import AppKit

final class TonePlayer {
    static let shared = TonePlayer()
    func playStart() { NSSound(named: "Tink")?.play() }
    func playStop() { NSSound(named: "Pop")?.play() }
}
