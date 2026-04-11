//
//  PaywallView.swift
//  VoiceFlow
//
//  Full-screen paywall presented when:
//   - the user first launches the app (7-day Pro free trial offer)
//   - a free user hits their daily word limit
//   - a free user taps a Pro-gated feature (pack, tone, voice command,
//     custom vocab, Pro Polish)
//
//  Shows the three subscription plans with the yearly card highlighted
//  as "best value".
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var entitlements: EntitlementManager
    @Environment(\.dismiss) private var dismiss

    let reason: PaywallReason

    @State private var selectedPlan: SubscriptionProduct = .yearly

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    featureList
                    planPicker
                    ctaButton
                    restoreButton
                    legalFooter
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task { await entitlements.loadProducts() }
            .alert(
                "Purchase error",
                isPresented: Binding(
                    get: { entitlements.lastError != nil },
                    set: { if !$0 { entitlements.lastError = nil } }
                ),
                presenting: entitlements.lastError
            ) { _ in
                Button("OK", role: .cancel) { entitlements.lastError = nil }
            } message: { err in
                Text(err)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("VoiceFlow Pro")
                .font(.largeTitle.bold())
            Text(reason.headline)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaywallFeature(icon: "infinity", text: "Unlimited dictation cleanup")
            PaywallFeature(icon: "brain", text: "Pro Polish with Claude Sonnet 4.6")
            PaywallFeature(icon: "books.vertical.fill", text: "All vocab packs, including Professional")
            PaywallFeature(icon: "pencil.and.list.clipboard", text: "Custom vocabulary (always on)")
            PaywallFeature(icon: "mic.circle.fill", text: "All voice commands")
            PaywallFeature(icon: "paintpalette.fill", text: "All tone presets (Slack, Social, Professional)")
            PaywallFeature(icon: "bolt.fill", text: "Shortcuts, Share extension, Action Button")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var planPicker: some View {
        VStack(spacing: 12) {
            ForEach(SubscriptionProduct.allCases) { plan in
                PlanCard(
                    plan: plan,
                    isSelected: selectedPlan == plan,
                    storeProduct: entitlements.products[plan]
                )
                .onTapGesture { selectedPlan = plan }
            }
        }
    }

    private var ctaButton: some View {
        Button {
            Task {
                await entitlements.purchase(selectedPlan)
                if entitlements.hasPro {
                    dismiss()
                }
            }
        } label: {
            Group {
                if entitlements.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(ctaLabel)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var ctaLabel: String {
        if selectedPlan == .lifetime { return "Unlock Lifetime" }
        return "Start 7-day Free Trial"
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task { await entitlements.restore() }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("Cancel anytime in Settings. Subscriptions auto-renew.")
            Text("Terms of Service  •  Privacy Policy")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
}

// MARK: - Subviews

private struct PaywallFeature: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(text)
                .font(.body)
            Spacer()
        }
    }
}

private struct PlanCard: View {
    let plan: SubscriptionProduct
    let isSelected: Bool
    let storeProduct: Product?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(plan.title)
                        .font(.headline)
                    if plan.isFeatured {
                        Text("BEST VALUE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                Text(displayPrice + " " + plan.period)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let savings = plan.savingsCopy {
                    Text(savings)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    /// Prefer the real StoreKit-localized price if it loaded;
    /// otherwise fall back to the hard-coded display price.
    private var displayPrice: String {
        // StoreKit `Product.displayPrice` is localized and formatted.
        if let p = storeProduct {
            return p.displayPrice
        }
        return plan.displayPrice
    }
}

#Preview {
    PaywallView(reason: .manual)
        .environmentObject(EntitlementManager.shared)
}
