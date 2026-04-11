# VoiceFlow

**Voice-powered clipboard for professionals whose IT department blocks third-party keyboards.**

Most corporate-managed iPhones lock down Outlook, Teams, Slack, Salesforce, and any MDM container so third-party keyboards can't be used inside them. That means voice dictation keyboards like Wispr Flow are a non-starter at work — exactly when you'd want them most.

VoiceFlow flips the model: instead of replacing the keyboard, it's a voice-powered clipboard. Tap the Action Button, speak, and a clean, AI-polished transcript lands on your iPhone clipboard. Paste it anywhere with the built-in system keyboard — including every locked-down corporate app. Paste on your Mac via Universal Clipboard for desktop workflows.

---

## The hero flow: Quick Dictate

```
Action Button → speak → auto-stop on silence → polished text
on clipboard → tap a paste target icon → you're in Outlook, done.

   Target: under 5 seconds button-to-clipboard, under 8 seconds
   button-to-pasted-in-destination.
```

Quick Dictate is the default interaction model. It's exposed as:
- An **App Intent** (`QuickDictateIntent`) so it appears in the Action Button picker, Lock Screen widget gallery, Control Center, Shortcuts, and Siri.
- An in-app prominent CTA above the main DictationView.
- A full-screen minimal UI (`QuickDictateView`) with a live waveform, streaming transcript, and a single big **Done** button.

When it finishes you get a **2-second confirmation banner** with a checkmark, the first 60 characters of the polished text, and up to 4 user-configured **paste target** buttons (Outlook, Teams, Slack, Mail, Messages, Notes by default). One tap on any target launches that app with your clean text already on the clipboard.

---

## Architecture

```
VoiceFlow/
├── README.md
├── .gitignore
├── ios/
│   ├── VoiceFlow.xcodeproj/
│   └── VoiceFlow/
│       ├── VoiceFlowApp.swift          # @main, wires managers, picks onboarding vs. main
│       ├── Secrets.swift                # (gitignored) Anthropic API key
│       ├── Secrets.swift.example
│       ├── Info.plist                   # mic/speech/alt-icon keys
│       ├── Assets.xcassets/
│       │   ├── AppIcon.appiconset/
│       │   └── AppIcon-Discreet.appiconset/   # monochrome alt icon for Discreet Mode
│       ├── Core/
│       │   ├── DictationEngine.swift         # SFSpeechRecognizer, 55s rotation, silence detection, audioLevel, polish()
│       │   ├── ClaudeCleanup.swift           # Claude Messages API client (haiku / sonnet model switch)
│       │   ├── VoiceCommandParser.swift      # wake-word command registry (copy that / clear / new paragraph / stop / send to)
│       │   ├── VocabPackManager.swift        # loads packs, merges active ones into cleanup prompt
│       │   ├── EntitlementManager.swift      # StoreKit 2, hasPro, free-tier word counter
│       │   ├── UsageTracker.swift            # local-only analytics scaffold
│       │   ├── PasteTargetsManager.swift     # configured destination apps + banner launcher
│       │   └── AppSettings.swift             # Discreet Mode, silence threshold, autocopy, onboarding flag
│       ├── Views/
│       │   ├── DictationView.swift           # secondary full in-app experience
│       │   ├── QuickDictateView.swift        # hero full-screen minimal UI
│       │   ├── RecentDictationsView.swift    # last 5 (free) / 20 (pro) history
│       │   ├── PasteTargetsView.swift        # reorder/add/remove paste destinations
│       │   ├── OnboardingView.swift          # 6-step first-launch flow
│       │   ├── VocabPackPickerView.swift     # packs grouped by category + download toggles
│       │   ├── PaywallView.swift             # StoreKit 2 paywall
│       │   ├── SettingsView.swift            # incl. "Use VoiceFlow at Work" (Universal Clipboard guide)
│       │   └── TonePresetPicker.swift
│       ├── Models/
│       │   ├── TonePreset.swift              # verbatim / email / slack / notes / socialPost / professional
│       │   ├── VocabPack.swift               # schema + VocabPackCatalog
│       │   ├── Subscription.swift            # product IDs, FreeTierLimits
│       │   ├── DictationHistory.swift        # local entry model + on-disk store
│       │   └── PasteTarget.swift             # user-configurable destinations + defaults
│       ├── Intents/
│       │   └── VoiceFlowIntents.swift        # QuickDictateIntent (hero), GetLastDictationIntent, etc.
│       ├── Extensions/
│       │   └── ShareExtensionPlaceholder.swift  # stub, add real target via Xcode
│       └── Resources/
│           ├── software-dev.json             # bundled free starter pack
│           ├── general-business.json         # bundled free starter pack
│           ├── medical-general.json          # bundled free starter pack
│           └── catalog.json                  # stub remote catalog (static, points at local bundle)
└── vocab-packs/
    ├── manifest.json
    ├── software-dev.json
    ├── general-business.json
    ├── medical-general.json
    ├── corporate-law.json        (pro)
    ├── real-estate.json          (pro)
    ├── construction.json         (pro)
    ├── finance-banking.json      (pro)
    ├── marketing-advertising.json (pro)
    ├── management-consulting.json (pro)
    ├── healthcare-nursing.json   (pro)
    └── accounting-tax.json       (pro)
```

### Cleanup pipeline

```
 mic audio ─► SFSpeechRecognizer (partial results)
                │
                ▼
           liveTranscript ─► VoiceCommandParser.scan()
                                 │             (commands stripped out)
                                 ▼
                        DictationEngine.polish()
                                 │
                                 ▼
                        ClaudeCleanup.clean(
                          rawTranscript,
                          tone: TonePreset,
                          packPromptHints + packTermsBlock,
                          model: .haiku | .sonnet
                        )
                                 │
                                 ▼
                        polishedTranscript
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
      UIPasteboard       DictationHistory       Confirmation
      (auto-copy)        (local storage)         banner with
                                                 paste targets
```

### Cleanup prompt shape

Every cleanup request layers:
1. Base rules (filler removal, punctuation, self-correction collapse, voice preservation).
2. **Active tone preset** fragment (see `TonePreset.systemPromptFragment`).
3. **Active vocab pack promptHints** joined into a domain-context sentence.
4. **Active vocab pack terms/phrases**, deduped, bullet-listed, with an instruction to preserve exact spelling and capitalization.
5. **Custom vocabulary** (Pro only) merges as a highest-priority always-on pack.

### Voice commands

Default wake word is "VoiceFlow" (configurable in Settings). Built-in commands (see `VoiceCommandParser.defaultCommands()`):

| Phrase | Free | Action |
|---|---|---|
| `<wake> copy that` | ✅ | Copy polished/raw transcript to clipboard |
| `<wake> clear` | ✅ | Wipe live + polished buffers |
| `<wake> stop` | ✅ | End session, trigger cleanup |
| `<wake> new paragraph` | Pro | Insert `\n\n` into live transcript |
| `<wake> send to <app>` | Pro | Copy + open target via URL scheme |

Commands are matched on every partial-result update, deduped by fingerprint so they fire exactly once, stripped from the transcript before it reaches cleanup, and trigger a haptic + visible confirmation pill. New commands: append a `VoiceCommand` struct to `VoiceCommandParser.defaultCommands()` — no other wiring needed.

---

## Tiers

### Free
- **2,000 words/day** of AI cleanup (daily reset, tracked in UserDefaults)
- Claude **Haiku 4.5** only (`claude-haiku-4-5-20251001`)
- **3 starter vocab packs**: software-dev, general-business, medical-general
- **3 tone presets**: Verbatim, Email, Notes
- **Voice commands**: copy that, clear, stop
- **Recent dictations**: last 5 entries
- Quick Dictate, Paste Targets, Universal Clipboard guide — all fully functional

### Pro — starts with a 7-day free trial
- **Unlimited** cleanup
- **Pro Polish** — route cleanup through Claude **Sonnet 4.6** (`claude-sonnet-4-6`) for higher-quality edits
- **All vocab packs** (11 total, all bundled)
- **Custom Vocabulary** always-on personal pack (replacement rules, names, team-specific acronyms)
- **All tone presets** (adds Slack, Social Post, Professional)
- **All voice commands** (adds new paragraph, send to app)
- **Recent dictations**: full 20 entries
- **Discreet Mode**: monochrome alternate icon, dark-mode default, subdued palette

### Pricing
| Plan | Price | Notes |
|---|---|---|
| Monthly | **$12/mo** | Standard subscription |
| Yearly | **$96/yr** | ⭐ Best value — 33% savings, highlighted on paywall |
| Lifetime | **$199** one-time | Non-consumable IAP |

Product IDs (declare in App Store Connect and a `Products.storekit` config file):
- `voiceflow.pro.monthly`
- `voiceflow.pro.yearly`
- `voiceflow.pro.lifetime`

Paywall appears on first launch (with the 7-day trial offer), on daily word-limit exhaustion, and on any Pro-gated feature tap.

---

## Vocab packs

### Schema

```json
{
  "name": "Pack Display Name",
  "version": "1.0.0",
  "description": "Short sentence shown in the picker.",
  "category": "free" | "pro" | "professional",
  "bundleId": "com.hak-tx.voiceflow.pack.example",
  "terms": ["API", "REST", "..."],
  "phrases": ["ship it", "looks good to me"],
  "promptHints": "One or two sentences describing the speaker's profession and preferred terminology conventions."
}
```

- `promptHints` is injected verbatim into the cleanup system prompt when the pack is active.
- `terms` and `phrases` are merged + deduped across all active packs and sent to Claude as a "preserve these exact spellings" block.
- `category` and `bundleId` are reserved for future use — **there is no marketplace or per-pack purchasing in v1**. All Pro packs are unlocked together with the Pro subscription.

### Packs in v1

| Pack | Category | ~Term count | Audience |
|---|---|---|---|
| Software Development | Free | ~210 | Engineers, SREs, PMs |
| General Business | Free | ~180 | Any corporate role |
| Medical (General) | Free | ~170 | Physicians, PAs, NPs |
| Corporate Law | Pro | ~180 | Transactional / in-house attorneys |
| Real Estate | Pro | ~190 | Agents, brokers, property managers |
| Construction | Pro | ~200 | GCs, supers, field staff |
| Finance & Banking | Pro | ~200 | IB, PE/VC, corp finance |
| Marketing & Advertising | Pro | ~200 | Brand + performance marketers |
| Management Consulting | Pro | ~180 | Strategy + ops consultants |
| Healthcare & Nursing | Pro | ~180 | RNs, allied health |
| Accounting & Tax | Pro | ~210 | CPAs, controllers, tax pros |

### Adding a new pack

1. Drop a JSON file under `/vocab-packs/your-domain.json` following the schema above.
2. Add an entry to `/vocab-packs/manifest.json` with `id`, `name`, `file`, `version`, `description`, `termCount`, and `category`.
3. To bundle it with the app: copy to `ios/VoiceFlow/Resources/` and add it to the Xcode project's Resources build phase.
4. For catalog-served packs (future), the manager downloads from `VocabPackManager.remoteCatalogURL` — currently stubbed to the bundled `catalog.json`.

---

## Setup

You'll need macOS + Xcode 15 or newer, Homebrew, and an Anthropic API key.

**TL;DR — first-run bootstrap:**

```sh
git clone git@github.com:hak-tx/VoiceFlow.git
cd VoiceFlow
# Create ~/.voiceflow.env with your secrets (see DEPLOY.md step 5)
./Scripts/bootstrap.sh
open ios/VoiceFlow.xcodeproj
```

The bootstrap script installs XcodeGen + fastlane, regenerates
`ios/VoiceFlow.xcodeproj` from `ios/project.yml`, writes
`ios/VoiceFlow/Secrets.swift` from `$ANTHROPIC_API_KEY`, and
sanity-checks that the project parses.

For TestFlight deployment (sign + archive + upload in one command),
see **[DEPLOY.md](DEPLOY.md)**.

### Manual setup (if you skip the bootstrap script)

1. **Clone the repo** and `cd VoiceFlow`.
2. **Create your `Secrets.swift`** (gitignored):
   ```sh
   export ANTHROPIC_API_KEY=sk-ant-...
   ./Scripts/generate-secrets.sh
   ```
3. **Regenerate the Xcode project** from the YAML spec so you get a clean pbxproj:
   ```sh
   brew install xcodegen
   cd ios && xcodegen generate
   ```
4. **Open the project**: `open ios/VoiceFlow.xcodeproj`
5. **Pick your signing team.** `VoiceFlow` target → Signing & Capabilities → your Apple Developer team.
6. **(Optional but recommended for simulator testing) Add a StoreKit configuration file.** File → New → File → StoreKit Configuration File → name it `Products.storekit`. Add `voiceflow.pro.monthly`, `voiceflow.pro.yearly`, `voiceflow.pro.lifetime`. Then Scheme → Edit Scheme → Run → Options → StoreKit Configuration → pick `Products.storekit`. Until you do this, `EntitlementManager.loadProducts()` returns empty and the paywall shows hard-coded display prices.
7. **Build and run.** Target is iOS 17+. First launch shows the 6-step onboarding flow ending on a guided dictation. After that the app asks for Microphone and Speech Recognition permissions — grant both.

### iOS permission prompts / Info.plist keys already configured
- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`
- `LSApplicationQueriesSchemes` (for paste target URL schemes: ms-outlook, msteams, slack, mailto, sms, mobilenotes, drafts, bear, things, todoist)
- `CFBundleIcons → CFBundleAlternateIcons → AppIcon-Discreet` (asset slot is created but needs actual PNG files added in Xcode before Discreet Mode will switch icons)

---

## Use VoiceFlow at Work — Universal Clipboard

The core corporate pitch: dictate on your iPhone, paste on your Mac desktop, in any app — including corporate Outlook, Teams desktop, Salesforce, or any MDM-locked container.

How it works:
1. Dictate on iPhone with Quick Dictate (Action Button, Lock Screen, or in-app).
2. Polished text is already on your iPhone clipboard.
3. Switch to your Mac and press Cmd-V in any app.

Requirements:
- Both devices signed in with the same Apple ID
- Same Wi-Fi network
- Bluetooth on
- Handoff enabled (Settings → General → AirPlay & Handoff)

The in-app **Settings → Use VoiceFlow at Work** section shows a step-by-step version of this for the end user.

---

## Roadmap — what's stubbed vs implemented

### ✅ Implemented end-to-end
- DictationEngine with live partial results, 55s session rotation + stitching, audioLevel RMS tracking, silence auto-stop hook
- ClaudeCleanup with tone + pack injection and Haiku/Sonnet model selection
- VoiceCommandParser with 5 default commands and a drop-in registry for more
- VocabPackManager with bundled pack loading, (stub) remote catalog fetch, active selection persistence, custom vocab synthesis
- 11 vocab packs in `/vocab-packs`, 3 bundled in `Resources`
- EntitlementManager with StoreKit 2 wiring, hasPro, free-tier daily word counter, trial-offer first-launch gate
- UsageTracker local counters (dictations, words, voice commands, tone presets, active packs)
- QuickDictateView (waveform, auto-stop, clipboard + banner + paste targets)
- DictationView secondary experience with action bar (Select All / Copy / Clear / Undo / Share / Tone) and vocab pack + settings toolbar
- RecentDictationsView (free 5 / Pro 20) with copy + share
- PasteTargetsManager + PasteTargetsView (reorder/add/remove)
- AppSettings (Discreet Mode, silence threshold slider, autocopy toggle, onboarding flag)
- 6-step OnboardingView (problem → permissions → Action Button → paste targets → guided dictation → Universal Clipboard)
- SettingsView including the "Use VoiceFlow at Work" Universal Clipboard guide
- PaywallView with 3 plans, yearly highlighted, 7-day trial CTA, restore
- VoiceFlowIntents: QuickDictate (hero), GetLastDictation, DictateWithVoiceFlow, DictateAndCopy, DictateAndShareToApp, all via AppShortcutsProvider

### 🚧 Stubbed / needs follow-up
- **Share Extension target** — `ShareExtensionPlaceholder.swift` documents the contract, but the actual extension requires a new target via Xcode's File → New → Target → Share Extension.
- **Discreet Mode alternate icon** — asset slot + Info.plist entry are wired, but actual PNG files need to be added to `AppIcon-Discreet.appiconset/` before `UIApplication.setAlternateIconName` will succeed.
- **Remote catalog** — `VocabPackManager.remoteCatalogURL` currently falls back to the bundled `catalog.json`. Point this at a real HTTPS CDN before public release.
- **Pack download** — `downloadPack()` currently copies from the app bundle since all packs ship bundled. Wire real HTTPS download once the CDN exists.
- **GetLastDictationIntent** — returns the clipboard string for now because `DictationHistoryStore` lives in the app sandbox. Move it to an App Group (suite `group.com.hak-tx.voiceflow`) so background intents can read it without opening the app.
- **App Group for the Share Extension** — same App Group enables the extension to read/write `TonePreset`, `VocabPackManager` state, and history.
- **Background audio** — the mic tap stops if the app is backgrounded. For true "dictate with screen off," add the `audio` background mode and handle `AVAudioSession` interruptions in `DictationEngine`.
- **Real Xcode icon artwork** — the `AppIcon.appiconset` and `AppIcon-Discreet.appiconset` contain only schema JSON; add real 1024×1024 PNGs.
- **StoreKit configuration file** — not checked in. Create `Products.storekit` in Xcode so the paywall has real prices / purchase flow during development.
- **Session rotation audio gap** — removing and re-installing the audio tap at the 55s mark drops a few hundred ms of audio. Fix by overlapping two requests.
- **Creator marketplace / per-pack purchases** — intentionally removed from v1. `VocabPack.category` and `bundleId` fields are kept in the schema for future use.

---

## Goals

- Make voice dictation work in every iOS app, especially the MDM-locked corporate ones, by sidestepping the keyboard entirely.
- Ship a better polish pass than Wispr Flow by layering tone presets + domain vocab on top of Claude cleanup.
- Get from "thought" to "pasted in Outlook" in under 8 seconds with zero screen taps after the initial Action Button press.
