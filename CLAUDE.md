# Bani — iOS personal-finance app (Swift, XcodeGen, AltStore distribution)

Start every session here: read `handoffs/LATEST.md`, then `git log -10 --oneline`, then continue the phase it names. Do not re-read the vault for context; `PLAN.md`, `ROADMAP.md`, `HANDOFF.md` in this repo are the truth.

## Build & test (the gate)
- `xcodegen generate` → `xcodebuild build test -scheme Bani -destination 'platform=iOS Simulator,name=iPhone 16'` (mirrors `.github/workflows/ci.yml` job `gate`).
- Unit tests live in `BaniTests/`; UI tests in `BaniUITests/` (CI job `screenshots`).
- Marketing version comes ONLY from `BANI_MARKETING_VERSION` in `ci.yml`; CI stamps `<version>.<run>` into the IPA and `docs/source.json`. Never hardcode a version anywhere else.

## Done condition
A push is done when CI is green on `main` (`gh run list -L1 --workflow CI`) and `docs/source.json` version equals the IPA's CFBundleShortVersionString (CI verifies). "Installed on the phone" is D's eyeball, not the gate.

## Rules
- One phase per session; commit per phase; end the session with a commit or stash and an updated `handoffs/LATEST.md` (≤ 8 lines: state, last commit, next step, open items).
- Hints first when D is learning; full code on "do it for me" or a deadline inside 48h.
- Stop asking for confirmation on steps already in `PLAN.md`; ask only on scope changes.
