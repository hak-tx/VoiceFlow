#!/usr/bin/env bash
#
# bootstrap.sh
#
# First-run Mac setup for VoiceFlow. Installs dependencies,
# regenerates the Xcode project, writes Secrets.swift, and verifies
# the build can run. Idempotent — safe to rerun.
#
# Usage:
#   ./Scripts/bootstrap.sh
#
# Prerequisites (check first):
#   - macOS + Xcode 15 or newer
#   - Homebrew installed (https://brew.sh)
#   - An Anthropic API key (set $ANTHROPIC_API_KEY or create
#     ~/.voiceflow.env with a single line: ANTHROPIC_API_KEY=sk-ant-...)
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. Preflight -----------------------------------------

[[ "$(uname)" == "Darwin" ]] || die "bootstrap.sh only runs on macOS."
command -v brew >/dev/null || die "Homebrew not found. Install from https://brew.sh first."
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode from the App Store."

# ---------- 1. Install toolchain ---------------------------------

say "Installing XcodeGen…"
if ! command -v xcodegen >/dev/null; then
    brew install xcodegen
fi

say "Installing fastlane (via bundler)…"
if ! command -v bundle >/dev/null; then
    # Ruby + bundler come with macOS; install bundler if missing.
    if ! gem list bundler -i >/dev/null 2>&1; then
        gem install --user-install bundler
        say "Installed bundler. You may need to add ~/.gem/ruby/*/bin to PATH."
    fi
fi
(
    cd "$REPO_ROOT/ios"
    bundle config set --local path 'vendor/bundle' >/dev/null
    bundle install --quiet
)

# ---------- 2. Regenerate Xcode project --------------------------

say "Regenerating Xcode project from project.yml…"
(
    cd "$REPO_ROOT/ios"
    xcodegen generate
)

# ---------- 3. Generate Secrets.swift ----------------------------

say "Writing Secrets.swift…"
"$REPO_ROOT/Scripts/generate-secrets.sh"

# ---------- 4. Sanity check: does the project open? --------------

say "Running a no-op xcodebuild -list to verify the project parses…"
xcodebuild -list -project "$REPO_ROOT/ios/VoiceFlow.xcodeproj" >/dev/null \
    || die "xcodebuild couldn't parse the project. Something's wrong with project.yml."

# ---------- 5. Done ----------------------------------------------

cat <<EOF

\033[1;32m✓ Bootstrap complete.\033[0m

Next steps:

  1. Open the project:
       open ios/VoiceFlow.xcodeproj

  2. Pick your signing team (first time only):
       VoiceFlow target → Signing & Capabilities → Team.
     Or set VOICEFLOW_TEAM_ID in ~/.voiceflow.env and skip this step.

  3. To build & upload a TestFlight build:
       cd ios && bundle exec fastlane beta

  See DEPLOY.md for the full checklist.

EOF
