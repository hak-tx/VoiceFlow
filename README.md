# VoiceFlow

Live voice-to-text on iOS with an AI cleanup pass.

VoiceFlow gives you the keyboard-style dictation flow you get from the iOS
system keyboard — words appearing in real time as you speak — but with a
post-stop cleanup step powered by **Claude Haiku 4.5** that strips filler
words, fixes punctuation, and preserves your voice. Think of it as the iOS
dictation stream + Wispr Flow's post-edit, in one app.

It also supports **vocabulary packs** so you can tell the cleanup model
about your domain (software engineering, construction, corporate law, etc.)
and have industry terms, acronyms, and lingo preserved exactly.

---

## Architecture

```
+----------------------+
|      DictationView   |   SwiftUI: big mic button, scrolling transcript,
|      (SwiftUI)       |   undo button. Shows live transcript while
+----------+-----------+   recording, swaps to polished on stop.
           |
           v
+----------------------+       +------------------------+
|   DictationEngine    |<----->|    VocabPackManager    |
|   @MainActor         |       |  Loads packs, tracks   |
|                      |       |  active selection,     |
|  * SFSpeechRecognizer|       |  builds prompt hints + |
|    + partial results |       |  term list for inject. |
|  * AVAudioEngine tap |       +-----------+------------+
|  * 55s session       |                   |
|    rotation &        |                   |
|    stitching         |                   v
|  * polish() ->       |       +------------------------+
|    AnthropicClient   |------>|    Anthropic API       |
+----------+-----------+       | claude-haiku-4-5-      |
           |                   | 20251001 /messages     |
           v                   +------------------------+
  liveTranscript (Published)
  polishedTranscript (Published)
```

### Key pieces

- **`DictationEngine.swift`** — owns microphone + speech recognition. Uses
  `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults
  = true` so text streams in as you speak. Apple caps a single recognition
  request at ~1 minute; the engine rotates to a fresh session at **55
  seconds**, appends the finalized text to `stitchedSegments`, and keeps
  going without the user noticing. On `stop()`, it calls `polish()` which
  ships the full raw transcript to Claude Haiku 4.5 and writes the
  cleaned-up result to `polishedTranscript`.
- **`DictationView.swift`** — the UI. Giant mic button, scrolling
  transcript area, undo button. The transcript area shows the live
  stream while `isRecording` is true and automatically swaps to the
  polished version once cleanup finishes. Undo wipes the polished
  version and falls back to the raw stitched transcript.
- **`VocabPackManager.swift`** — reads pack JSON files out of the app's
  `Documents/vocab-packs/` directory (plus any seed copies bundled with
  the app), lets the user toggle which are "active", and exposes
  `combinedPromptHints()` + `combinedTermsBlock()` that the dictation
  engine splices into the cleanup system prompt.
- **`Secrets.swift`** — gitignored file holding your Anthropic API key.
  See setup below.

### Cleanup prompt shape

At request time, `DictationEngine` builds a system prompt that looks
like:

```
You are a transcript cleanup assistant...
1. Remove filler words...
2. Fix punctuation...
3. Collapse self-corrections...
4. Preserve the speaker's voice...
5. Output ONLY the cleaned transcript.

Domain context: <active pack promptHints joined>

The speaker may use these domain terms; preserve their exact spelling
and capitalization:
- API
- pull request
- ...
```

The raw transcript is sent as the `user` message; the cleaned output
becomes `polishedTranscript`.

---

## Vocab packs

Packs live in `/vocab-packs` at the repo root and follow this schema:

```json
{
  "name": "Software Development",
  "version": "1.0.0",
  "description": "Common software engineering terms...",
  "terms": ["API", "REST", "..."],
  "phrases": ["ship it", "looks good to me", "..."],
  "promptHints": "The speaker is a software engineer dictating..."
}
```

- `name` — human-readable pack name (used as the identity key).
- `version` — semver-ish string for the pack.
- `description` — short sentence shown in the picker UI.
- `terms` — single-word or short technical tokens the model should
  preserve verbatim.
- `phrases` — idiomatic multi-word expressions in the domain.
- `promptHints` — a sentence (or few) describing the speaker's context
  that gets injected directly into the cleanup system prompt when the
  pack is active.

### Adding a new pack

1. Create a new JSON file under `/vocab-packs/your-domain.json`
   following the schema above.
2. Add an entry to `/vocab-packs/manifest.json` with the `id`, `name`,
   `file`, `version`, `description`, and approximate `termCount`.
3. To use it in the app during development, drop the JSON file into
   the app's `Documents/vocab-packs/` directory (easiest: use the Files
   app, or drag into the simulator via Finder). Restart the app and
   toggle the pack on in the **Vocab Packs** sheet.
4. (Future work) A server-side catalog can fetch the manifest and
   offer packs for download from within the app.

### Currently shipping packs

- **`software-dev.json`** — 50 software engineering terms + 10 phrases.

Planned: `construction.json`, `corporate-law.json`, `medical.json`,
`finance.json`, etc.

---

## Setup

You'll need macOS + Xcode 15 or newer.

1. **Clone the repo**
   ```sh
   git clone git@github.com:hak-tx/VoiceFlow.git
   cd VoiceFlow
   ```

2. **Create your `Secrets.swift`** (it's gitignored so it won't be
   committed). From the repo root:
   ```sh
   cp ios/VoiceFlow/Secrets.swift.example ios/VoiceFlow/Secrets.swift
   ```
   Then edit `ios/VoiceFlow/Secrets.swift` and replace
   `sk-ant-REPLACE-ME` with your real key from
   https://console.anthropic.com/.

3. **Open the project**
   ```sh
   open ios/VoiceFlow.xcodeproj
   ```

4. **Pick your signing team.** Select the `VoiceFlow` target →
   Signing & Capabilities → choose your Apple Developer team. The
   bundle ID `com.hak-tx.voiceflow` is set for you, but you can change
   it if the default conflicts with something in your account.

5. **Build and run.** Target is iOS 17+. On first launch the app will
   ask for Microphone and Speech Recognition permissions — grant both,
   then tap the mic button and start talking.

### Using vocab packs in the simulator

1. Run the app once so its Documents directory exists.
2. Copy files from `/vocab-packs/*.json` into the simulator's
   Documents directory. Easiest path in Xcode:
   `Window → Devices and Simulators → Simulators → Download Container…`,
   or use `xcrun simctl get_app_container booted com.hak-tx.voiceflow data`
   to find the sandbox, then drop the JSONs into `Documents/vocab-packs/`.
3. Relaunch the app and toggle packs via the books icon in the nav
   bar.

---

## Goals / roadmap

- Match the iOS system keyboard's "text streams in as you speak" feel.
- Layer a Wispr Flow-style AI cleanup on stop that removes filler,
  fixes punctuation, and respects your voice.
- Downloadable industry vocab packs (construction, software, law,
  medicine, finance, etc.) so specialized terminology is preserved.
- Future: share sheet action so you can dictate into any iOS app.

---

## Repository layout

```
VoiceFlow/
├── README.md
├── .gitignore
├── ios/
│   ├── VoiceFlow.xcodeproj/
│   └── VoiceFlow/
│       ├── VoiceFlowApp.swift        # @main app entry
│       ├── DictationView.swift       # SwiftUI UI
│       ├── DictationEngine.swift     # Speech + Anthropic cleanup
│       ├── VocabPackManager.swift    # Pack loader + prompt injection
│       ├── Secrets.swift              # (gitignored) API key
│       ├── Secrets.swift.example     # template to copy
│       ├── Info.plist                 # mic + speech usage strings
│       ├── Assets.xcassets/
│       └── Preview Content/
└── vocab-packs/
    ├── manifest.json
    └── software-dev.json
```
