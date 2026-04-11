//
//  Subscription.swift
//  VoiceFlow
//
//  Pure data model for the VoiceFlow subscription tiers. No StoreKit
//  imports here — `EntitlementManager.swift` handles the StoreKit 2
//  glue and just exposes a `hasPro` Published property.
//
//  Pricing (also declared in App Store Connect):
//    voiceflow.pro.monthly   - $12/mo
//    voiceflow.pro.yearly    - $96/yr  (33% off monthly)
//    voiceflow.pro.lifetime  - $199 one-time
//

import Foundation

enum SubscriptionTier: String, Codable {
    case free
    case pro
}

enum SubscriptionProduct: String, CaseIterable, Identifiable {
    case monthly  = "voiceflow.pro.monthly"
    case yearly   = "voiceflow.pro.yearly"
    case lifetime = "voiceflow.pro.lifetime"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly:  return "Monthly"
        case .yearly:   return "Yearly"
        case .lifetime: return "Lifetime"
        }
    }

    var displayPrice: String {
        switch self {
        case .monthly:  return "$12"
        case .yearly:   return "$96"
        case .lifetime: return "$199"
        }
    }

    var period: String {
        switch self {
        case .monthly:  return "per month"
        case .yearly:   return "per year"
        case .lifetime: return "one-time"
        }
    }

    /// Savings copy shown on the yearly plan to highlight best value.
    var savingsCopy: String? {
        switch self {
        case .yearly: return "Save 33% vs monthly"
        default:      return nil
        }
    }

    /// `true` for the card we want to visually highlight in the
    /// paywall. Yearly is the "best value" default.
    var isFeatured: Bool { self == .yearly }
}

/// Limits that apply to the free tier. Loaded by `EntitlementManager`.
struct FreeTierLimits {
    /// Daily cap on cleanup words.
    static let dailyWordLimit: Int = 2_000

    /// Starter packs bundled for free users.
    static let starterPackIds: [String] = [
        "software-dev",
        "general-business",
        "medical-general"
    ]

    /// Voice commands available on free tier (rest are Pro-gated).
    static let allowedVoiceCommands: Set<String> = [
        "copy that", "clear", "stop"
    ]

    static let allowedTonePresets: [TonePreset] = [
        .verbatim, .email, .notes
    ]

    static let allowsCustomVocab: Bool = false
    static let allowsProPolish: Bool = false
}

/// Reasons we might surface the paywall. Used by `PaywallView` to
/// swap the headline.
enum PaywallReason {
    case manual
    case dailyLimitReached
    case proFeatureGated(name: String)
    case voiceCommandGated(name: String)
    case customVocabGated
    case proPolishGated
    case packGated(name: String)

    var headline: String {
        switch self {
        case .manual:
            return "Unlock the full VoiceFlow experience."
        case .dailyLimitReached:
            return "You've used your 2,000 free words for today."
        case .proFeatureGated(let name):
            return "\(name) is a Pro feature."
        case .voiceCommandGated(let name):
            return "\"\(name)\" is a Pro voice command."
        case .customVocabGated:
            return "Custom vocabulary requires Pro."
        case .proPolishGated:
            return "Pro Polish (Claude Sonnet) requires Pro."
        case .packGated(let name):
            return "\(name) is a Pro vocab pack."
        }
    }
}
