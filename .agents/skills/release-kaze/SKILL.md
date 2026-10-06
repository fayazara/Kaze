---
name: release-kaze
description: "Release the Kaze macOS app to GitHub using the kaze-release CLI tool. Use this skill whenever the user wants to publish a new version, create a release, ship an update, cut a build, push a release to GitHub, or update the appcast. Also use when they mention archiving, notarization, DMG creation, Sparkle signing, bumping the version/build, or anything related to building and distributing a new Kaze version."
---

# Release Kaze

This skill releases new versions of Kaze using a Go CLI in this repo
(`cmd/kaze-release`). The CLI can run **fully automated and
non-interactively**, so a release can be triggered directly from a chat session.

There are two modes:

- **Full auto (`-build`)** - archive, export (Developer ID), notarize, staple,
  package, sign, and publish. Nothing in Xcode's GUI is required.
- **Package-only** (no `-build`) - assumes the user already exported a
  notarized `~/Downloads/Kaze.app` from Xcode, then packages & publishes.

Prefer **full auto** unless the user says they've already exported the app.

Publishing is outward-facing (GitHub release, appcast that existing users'
Sparkle reads). Confirm the version, build number and notes with the user
before running it.

## Prerequisites

Always required:

1. Tools installed: `create-dmg` (brew), `gh` (GitHub CLI, authenticated), `git`, `plutil`, `go`.
2. The Sparkle `sign_update` binary in DerivedData (created when the project is
   built/archived - the `-build` flow produces it automatically).

For **full auto (`-build`)** additionally:

3. `xcodebuild`, `xcrun`, `ditto` (all part of Xcode).
4. A **notarytool keychain profile**. The CLI defaults to `kaze-notary`.
   Notary credentials belong to the Apple developer account, not the app, so
   the profile already used for Screendrop works too:
   `-notary-profile screendrop-notary`. To create a dedicated one:
   ```bash
   xcrun notarytool store-credentials "kaze-notary" \
     --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

## The Release CLI

Source: `/Users/fayazahmed/Developer/fayazara/mac/Kaze/cmd/kaze-release/`

### Flags

- `-build` - run the archive → export → notarize → staple phase first.
- `-set-version <x.y.z>` - set `MARKETING_VERSION` before archiving (and commit it). Used with `-build`.
- `-set-build <n>` - set `CURRENT_PROJECT_VERSION` before archiving (and commit it). Used with `-build`.
- `-scheme <name>` - Xcode scheme to archive (default `Kaze`; never `Kaze Dev`).
- `-notes "<text>"` - release notes, one bullet per line (markdown `- ` prefixes are stripped). Skips the interactive prompt.
- `-notes-file <path>` - read release notes from a file instead.
- `-notary-profile <name>` - notarytool keychain profile (default `kaze-notary`).
- `-homebrew` - also publish/update `Casks/kaze.rb` in `fayazara/homebrew-tap`. Off by default because the tap has no Kaze cask yet; only pass it when the user wants Kaze on Homebrew.
- `-yes` / `-y` - assume "yes" for all confirmation prompts (non-interactive).

### Triggering a full release from here (recommended)

1. **Decide the version and build number.** The build number
   (`CURRENT_PROJECT_VERSION`) **must increase** every release or Sparkle won't
   offer the update. Check the current values:
   ```bash
   grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" \
     Kaze.xcodeproj/project.pbxproj | sort -u
   ```
   Pick the next `MARKETING_VERSION` (dotted semver, never regress) and
   `CURRENT_PROJECT_VERSION` = current + 1.
2. **Make sure code changes are committed and pushed** to `main` first, so the
   release tag points at the released source. (The CLI commits the version bump
   and pushes the appcast, but it does not push your other unrelated commits.)
3. **Run it** (non-interactive, safe to run from a tool call):
   ```bash
   cd /Users/fayazahmed/Developer/fayazara/mac/Kaze && \
   go run ./cmd/kaze-release -build -yes \
     -set-version <x.y.z> -set-build <n> \
     -notes "First note
   Second note"
   ```
   Notarization blocks for a few minutes - this is expected, not a hang. Use a
   generous tool timeout (~10 min; the archive also compiles MLX).

### Package-only (app already exported by the user)

```bash
cd /Users/fayazahmed/Developer/fayazara/mac/Kaze && \
go run ./cmd/kaze-release -yes -notes "Your notes here"
```

### What it does (in order)

With `-build`:
1. **Set version/build** (if `-set-version`/`-set-build` given) - edits pbxproj and commits.
2. **Archive** - `xcodebuild archive` (scheme `Kaze`, Release, `generic/platform=macOS`).
3. **Export** - `xcodebuild -exportArchive` with a generated Developer ID `ExportOptions.plist`.
4. **Notarize** - zips the app and runs `xcrun notarytool submit --wait`, verifying `status: Accepted`.
5. **Staple** - `xcrun stapler staple`, then places the app at `~/Downloads/Kaze.app`.

Then always:
6. **Preflight checks** + **validate** the app's version/build and Sparkle keys.
7. **Collect release notes** (from `-notes`/`-notes-file`, else stdin).
8. **Create DMG** with `create-dmg` → `~/Downloads/Kaze.dmg`.
9. **Sign DMG** with Sparkle `sign_update` (EdDSA).
10. **Push commits** - push any local commits (e.g. the version bump) to `main`.
11. **GitHub release** - `gh release create vX.Y.Z` with the DMG attached.
12. **Update + push appcast.xml** - prepend the new `<item>` (de-duping any entry for the same build), commit & push to `main`.
13. **Homebrew cask** - only with `-homebrew`.

The release is created **before** the appcast is pushed, so a published
appcast never points at a missing release. Network operations are retried with
backoff, and re-running is safe: an existing release gets the DMG re-uploaded
(`--clobber`) and the appcast entry for that build is replaced.

### Environment / constants

- Repo auto-detected at `~/Developer/fayazara/mac/Kaze` (override with `KAZE_REPO`).
- GitHub repo: `fayazara/Kaze` · branch: `main` · team: `TB2S44TFQS` · bundle: `com.fayazahmed.Kaze`.
- DMG volume: `Kaze` · minimum macOS: `26.0`.

## Sparkle Configuration

- **SUFeedURL**: `https://raw.githubusercontent.com/fayazara/Kaze/main/appcast.xml` (in `Kaze/Info.plist`)
- **SUPublicEDKey**: `MA/6n0fqT0T2updDlkXr8BjhJKoHWik9uf6Lh5pUG7U=`
- **UpdaterManager.swift**: starts at launch in Release builds only; "Check for Updates" lives in the menu bar and Settings > About.

## After releasing

```bash
gh release view v<x.y.z> --repo fayazara/Kaze --json tagName,assets -q '{tag: .tagName, assets: [.assets[].name]}'
git pull --ff-only origin main
```

## Troubleshooting

- **Partial failure / network error mid-release** - re-run the exact same command; the pipeline is idempotent.
- **notarytool credentials error** - the keychain profile is missing/invalid; pass `-notary-profile screendrop-notary` or create `kaze-notary` (see Prerequisites).
- **Notarization "Invalid"** - inspect with `xcrun notarytool log <submission-id> --keychain-profile <profile>` (usually signing/entitlements).
- **`xcodebuild archive` fails** - the CLI prints the last ~40 lines; confirm the scheme is `Kaze` (not `Kaze Dev`).
- **Kaze.app not found** (package-only mode) - export from Xcode first, or use `-build`.
- **sign_update not found** - build/archive the project once so DerivedData has the Sparkle artifacts.
- **gh auth** - run `gh auth login`.
- **Build already in appcast** - a *new* release needs a higher build number; bump `-set-build`.
