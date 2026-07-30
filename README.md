# Bani

A minimalist, on-device personal finance logger for iOS 26. Voice-first cash logging
in Romanian and English, two contexts (Personal / Work), dark + light mode.

- **Stack:** Swift 6 · SwiftUI · SwiftData · WhisperKit (on-device speech) · Foundation Models (availability-gated parsing) · BNR FX rates.
- **iPhone only, portrait only.** No backend, no accounts, no analytics.

## Build & install

There is no local Swift toolchain in this repo's workflow — **CI is the build**.
Every push runs GitHub Actions on a macOS runner:

- `build-test` — XcodeGen generates the project, builds, runs unit tests.
- `whisper-tests` — transcribes a bundled audio fixture (model cached).
- `screenshots` — captures Log / Finances / Settings in light + dark.
- `ipa` — archives an **unsigned** `Bani-unsigned.ipa` artifact.

**To install on your iPhone:** download `Bani-unsigned.ipa` from the latest green
run's artifacts → open it with AltStore → done (AltStore signs at install time).

## Project layout

- `project.yml` — XcodeGen spec (project is generated, never committed).
- `Bani/` — app source (synced folders; add Swift files with zero project edits).
- `BaniTests/`, `BaniUITests/` — unit + UI tests.
- `.github/workflows/ci.yml` — the four-job pipeline above.

▶ **Live preview (Appetize):** https://appetize.io/app/5yixs4bzmn6nothakxdqzwsfby — runs the latest `main` build in your browser.
