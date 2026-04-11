//
//  OnboardingView.swift
//  VoiceFlow
//
//  First-launch onboarding. Six steps:
//   1. The corporate-keyboard problem
//   2. Mic + speech permissions
//   3. Action Button / Lock Screen / Control Center setup
//   4. Paste Targets configuration (Outlook, Teams, Slack, ...)
//   5. Guided first dictation (end-to-end, into Notes)
//   6. Universal Clipboard tip (dictate on iPhone, paste on Mac)
//
//  Vocab packs and tone presets are intentionally NOT mentioned in
//  onboarding — they're discovery features surfaced later. We don't
//  want corporate users to bounce off the complexity.
//

import SwiftUI
import Speech
import AVFoundation
import UIKit

struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var pasteTargets: PasteTargetsManager

    @State private var step: Int = 0

    private let totalSteps = 7

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                step1_Problem.tag(0)
                step2_Permissions.tag(1)
                step3_ActionButton.tag(2)
                step4_PasteTargets.tag(3)
                step5_Keyboard.tag(4)
                step6_GuidedDictation.tag(5)
                step7_UniversalClipboard.tag(6)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            controlRow
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: - Steps

    private var step1_Problem: some View {
        OnboardingSlide(
            icon: "lock.shield",
            title: "Your IT department blocks third-party keyboards.",
            message:"""
            VoiceFlow works around that. Dictate anywhere, get a clean, \
            polished transcript on your clipboard, and paste it into \
            Outlook, Teams, Slack, or any other corporate app — \
            including the ones that lock down keyboards.
            """
        )
    }

    private var step2_Permissions: some View {
        OnboardingSlide(
            icon: "mic.fill",
            title: "Allow the microphone and speech recognition.",
            message:"We only listen when you explicitly tap Quick Dictate. Recording stops on silence or when you tap Done."
        ) {
            Button {
                Task { _ = await engine.requestPermissions() }
            } label: {
                Text("Allow Microphone & Speech")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.top, 12)
        }
    }

    private var step3_ActionButton: some View {
        OnboardingSlide(
            icon: "circle.grid.3x3.fill",
            title: "Put Quick Dictate where you can reach it.",
            message:"""
            On iPhone 15 Pro and newer, assign VoiceFlow to your Action \
            Button via Settings → Action Button → Shortcut → VoiceFlow → \
            Quick Dictate. You can also add it as a Lock Screen widget, \
            a Control Center toggle, or a Siri Shortcut.
            """
        )
    }

    private var step4_PasteTargets: some View {
        OnboardingSlide(
            icon: "arrow.up.right.square",
            title: "Pick your paste destinations.",
            message:"After every Quick Dictate, we'll show icons to jump straight into the apps where you paste most often. Tap to toggle."
        ) {
            VStack(spacing: 10) {
                ForEach(pasteTargets.targets.prefix(6)) { target in
                    HStack {
                        Image(systemName: target.symbolName)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        Text(target.name)
                        Spacer()
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                }
            }
            .padding(.top, 8)
        }
    }

    private var step5_Keyboard: some View {
        OnboardingSlide(
            icon: "keyboard.fill",
            title: "Install the VoiceFlow keyboard.",
            message:"""
            Works in consumer apps that aren't MDM-locked (Messages, \
            Safari, Notes). Full Access is required so the keyboard \
            can send your speech to Claude for cleanup — your voice \
            and text never go anywhere else.
            """
        ) {
            VStack(alignment: .leading, spacing: 10) {
                keyboardStep(
                    n: 1,
                    icon: "gearshape.fill",
                    text: "Open the iOS Settings app."
                )
                keyboardStep(
                    n: 2,
                    icon: "chevron.right",
                    text: "General → Keyboard → Keyboards → Add New Keyboard…"
                )
                keyboardStep(
                    n: 3,
                    icon: "plus.app.fill",
                    text: "Tap VoiceFlow under Third-Party Keyboards."
                )
                keyboardStep(
                    n: 4,
                    icon: "checkmark.shield.fill",
                    text: "Tap VoiceFlow in the list, then toggle Allow Full Access ON."
                )

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open iOS Settings")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(.top, 6)
            }
            .padding(.top, 4)
        }
    }

    private func keyboardStep(n: Int, icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.accentColor))
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }

    private var step6_GuidedDictation: some View {
        OnboardingSlide(
            icon: "checkmark.circle",
            title: "Try it — dictate something and paste into Notes.",
            message:"""
            Tap Quick Dictate below, say "This is my first VoiceFlow \
            dictation," let it auto-stop, then tap the Notes icon in the \
            confirmation banner. Paste in Notes to see it land cleanly.
            """
        ) {
            // The app wires the "Quick Dictate" button here externally;
            // the control row below advances the flow.
        }
    }

    private var step7_UniversalClipboard: some View {
        OnboardingSlide(
            icon: "laptopcomputer.and.iphone",
            title: "Bonus: Universal Clipboard.",
            message:"""
            Dictate on your iPhone, then paste on your Mac — in \
            corporate Outlook desktop, Teams desktop, Slack, anywhere. \
            Apple's Universal Clipboard carries the polished text \
            across devices automatically as long as both are signed in \
            with the same Apple ID, on the same Wi-Fi, and Bluetooth is on.
            """
        )
    }

    // MARK: - Controls

    private var controlRow: some View {
        VStack(spacing: 12) {
            ProgressDots(total: totalSteps, current: step)
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if step < totalSteps - 1 {
                        step += 1
                    } else {
                        settings.onboardingDone = true
                    }
                } label: {
                    Text(step < totalSteps - 1 ? "Next" : "Get Started")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Subviews

private struct OnboardingSlide<Extra: View>: View {
    let icon: String
    let title: String
    /// Renamed from `body` to avoid shadowing `View.body`.
    let message: String
    @ViewBuilder let extra: () -> Extra

    init(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.extra = extra
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: icon)
                    .font(.system(size: 60, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 32)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                extra()
                    .padding(.horizontal, 24)
                Spacer(minLength: 40)
            }
        }
    }
}

private struct ProgressDots: View {
    let total: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppSettings())
        .environmentObject(DictationEngine())
        .environmentObject(PasteTargetsManager())
}
