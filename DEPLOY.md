# Deploying VoiceFlow to TestFlight

From a fresh clone on your Mac to a TestFlight build you can install
on your phone, in about 10 minutes the first time.

## Prereqs

- macOS + Xcode 15 or newer (from the App Store)
- [Homebrew](https://brew.sh)
- A paid Apple Developer Program membership
- An App Store Connect account (comes with the Apple Developer Program)
- An Anthropic API key (`sk-ant-...`) from https://console.anthropic.com

## One-time Apple Developer setup

These steps only need to happen once. Most of them can be done from a
phone browser if you want to knock them out before sitting down at the Mac.

### 1. Register the bundle ID

https://developer.apple.com/account/resources/identifiers/list

- Click **+** → **App IDs** → **Continue** → **App**
- Description: `VoiceFlow`
- Bundle ID (Explicit): `com.hak-tx.voiceflow`
- Capabilities to enable:
  - **Speech Recognition** (required — we use `SFSpeechRecognizer`)
- Continue → Register

### 2. Create the App record in App Store Connect

https://appstoreconnect.apple.com/apps

- Click **+** → **New App**
- Platforms: **iOS**
- Name: `VoiceFlow`
- Primary Language: English (U.S.)
- Bundle ID: pick the `com.hak-tx.voiceflow` you just registered
- SKU: `voiceflow-ios-v1` (anything unique works)
- User Access: Full Access

### 3. Generate an App Store Connect API key

https://appstoreconnect.apple.com/access/integrations/api

- **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** tab
- Click **+** → Name: `VoiceFlow CI` → Access: **App Manager** → Generate
- Immediately download the `.p8` file — **Apple only lets you download it once.**
- Note the **Key ID** (shown next to the key name) and the **Issuer ID** (shown at the top of the page).
- Stash the `.p8` somewhere safe outside the repo, e.g. `~/.apple-keys/AuthKey_XXXXXXX.p8`.

### 4. Grab your Team ID

https://developer.apple.com/account → **Membership details** → **Team ID** (10-character string like `ABCD123XYZ`).

## Mac-side setup

### 5. Clone and bootstrap

```sh
git clone git@github.com:hak-tx/VoiceFlow.git
cd VoiceFlow
```

Create `~/.voiceflow.env` with your secrets (this file is gitignored
by default because it starts with a dot, and `.voiceflow.env` is in
`.gitignore`):

```sh
cat > ~/.voiceflow.env <<'EOF'
ANTHROPIC_API_KEY=sk-ant-REPLACE-WITH-YOUR-KEY
VOICEFLOW_APPLE_ID=you@example.com
VOICEFLOW_TEAM_ID=ABCD123XYZ
VOICEFLOW_APP_ID=com.hak-tx.voiceflow
VOICEFLOW_APP_STORE_CONNECT_KEY_ID=XXXXXXXXXX
VOICEFLOW_APP_STORE_CONNECT_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
VOICEFLOW_APP_STORE_CONNECT_KEY_PATH=/Users/you/.apple-keys/AuthKey_XXXXXXXXXX.p8
EOF
chmod 600 ~/.voiceflow.env
```

Then run the bootstrap:

```sh
./Scripts/bootstrap.sh
```

This will:
1. Install XcodeGen and fastlane (via Homebrew and bundler)
2. Regenerate `ios/VoiceFlow.xcodeproj` from `ios/project.yml`
3. Write `ios/VoiceFlow/Secrets.swift` from `$ANTHROPIC_API_KEY`
4. Run `xcodebuild -list` to sanity-check the project parses

### 6. Open the project and trust your signing team

```sh
open ios/VoiceFlow.xcodeproj
```

First time only: Xcode will show a warning about a missing
Development Team. Select the `VoiceFlow` target → **Signing &
Capabilities** → pick your team. Xcode will auto-create the
provisioning profile.

You can skip this step if you're only building via fastlane — the
`beta` lane passes `DEVELOPMENT_TEAM` via `xcargs` and uses
`-allowProvisioningUpdates` so Xcode auto-provisions at build time.

### 7. Build and upload a TestFlight build

```sh
cd ios
bundle exec fastlane beta
```

This runs:
1. `xcodegen generate` (re-syncs the project from `project.yml`)
2. `Scripts/generate-secrets.sh` (re-writes `Secrets.swift`)
3. `increment_build_number` — fetches the latest TestFlight build number and adds 1
4. `build_app` (fastlane's `gym`) — clean, archive, export signed IPA
5. `upload_to_testflight` (fastlane's `pilot`) — uploads the IPA via the App Store Connect API

First upload takes ~10 minutes end to end. Subsequent uploads are faster because Xcode/DerivedData caches the build.

### 8. Wait for processing, then install on your phone

Apple has to process the upload (usually 5–15 minutes — longer the
first time). You'll get an email from App Store Connect when it's
ready.

On your phone:
1. Install the **TestFlight** app from the App Store if you don't have it.
2. Open TestFlight → you'll see **VoiceFlow** under "Apps" (or tap the invite link from your email).
3. Tap **Install**.
4. First launch asks for microphone + speech recognition permissions. Grant both.

## Ongoing workflow

After the first build, shipping an update is three commands:

```sh
git pull
cd ios
bundle exec fastlane beta
```

Or if you've added/moved files and need the project.yml to pick them up:

```sh
cd ios && xcodegen generate && bundle exec fastlane beta
```

## Troubleshooting

### "No profiles for 'com.hak-tx.voiceflow' were found"

Either (a) the bundle ID isn't registered in the developer portal
(step 1 above), or (b) your Team ID is wrong. Double-check
`$VOICEFLOW_TEAM_ID` in `~/.voiceflow.env`.

### "The executable could not be found" or "Secrets.swift not found"

`Secrets.swift` didn't get generated. Run:
```sh
./Scripts/generate-secrets.sh
```
If `$ANTHROPIC_API_KEY` isn't in your environment, set it explicitly:
```sh
ANTHROPIC_API_KEY=sk-ant-... ./Scripts/generate-secrets.sh
```

### Xcode complains "Multiple commands produce Info.plist"

You probably opened the project with a stale `project.pbxproj`. Run:
```sh
cd ios && xcodegen generate
```
And reopen the project.

### Fastlane upload fails with "App not found"

The App record in App Store Connect doesn't exist yet (step 2 above).
TestFlight upload needs that record to exist *before* the first build
is uploaded.

### StoreKit paywall crashes / shows no products in simulator

Expected — StoreKit 2 needs a local configuration file for simulator
purchases.

Xcode → File → New → File → StoreKit Configuration File → name it
`Products.storekit` → add `voiceflow.pro.monthly`, `voiceflow.pro.yearly`,
`voiceflow.pro.lifetime`.

Then Scheme → Edit Scheme → Run → Options → StoreKit Configuration →
pick `Products.storekit`.

Only needed for local testing; TestFlight uses the real App Store
products you create in App Store Connect later.

### Build succeeds but TestFlight says "App Icon Missing"

The bundled placeholder icons are real PNGs, so this shouldn't happen,
but if you deleted them: drop a 1024×1024 PNG at
`ios/VoiceFlow/Assets.xcassets/AppIcon.appiconset/AppIcon.png` and
rerun `xcodegen generate`.

## Adding internal testers

Testers don't count against your 10,000-external limit and don't need
beta review. Fastest path:

1. App Store Connect → **Users and Access** → **Users** → add the
   email addresses you want, with the **Developer** role.
2. App Store Connect → **Apps** → **VoiceFlow** → **TestFlight** →
   **Internal Testing** → create a group → add those users.

Up to 100 internal testers, available immediately after a build
finishes processing. Perfect for you + a handful of first reviewers.

External testers (up to 10,000, no email required, just a public
link) need a one-time Beta App Review from Apple. Usually 24 hours or
less.
