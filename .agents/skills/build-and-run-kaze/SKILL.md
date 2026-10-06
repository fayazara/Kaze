---
name: build-and-run-kaze
description: "Build the Kaze macOS app with xcodebuild, kill any running instance (of any scheme), and launch the fresh build. Use this skill whenever the user asks to run, launch, relaunch, or try out the app, or says things like 'build and run' or 'restart the app'."
---

# Build and Run Kaze

This skill builds the Kaze macOS application via `xcodebuild`, kills any
running instance of the app (regardless of which scheme it was launched
from), then launches the newly built app.

## Steps

1. **Pick a scheme.** List the schemes available in the project:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "/Users/fayazahmed/Developer/fayazara/mac/Kaze/Kaze.xcodeproj" \
  -list 2>/dev/null | sed -n '/Schemes:/,$p' | tail -n +2
```

- The app schemes are `Kaze Dev` (Debug, bundle `com.fayazahmed.Kaze.dev`,
  product `Kaze Dev.app`) and `Kaze` (Release, bundle `com.fayazahmed.Kaze`).
  Ignore package schemes such as `argmax-oss-swift-Package`.
- Default to `Kaze Dev` unless the user names a scheme or asks for a Release
  build. The Dev build has its own bundle ID, so it keeps separate settings
  and permissions from an installed release copy.

2. **Resolve build settings for the chosen scheme** - don't hardcode the
   configuration or output path, since it varies per scheme:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "/Users/fayazahmed/Developer/fayazara/mac/Kaze/Kaze.xcodeproj" \
  -scheme "<SCHEME_NAME>" -showBuildSettings 2>/dev/null \
  | grep -E "^\s*(CONFIGURATION|BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME|EXECUTABLE_NAME) "
```

Use `CONFIGURATION` for the `-configuration` flag in the build step, and
`BUILT_PRODUCTS_DIR` + `FULL_PRODUCT_NAME` to construct the `.app` path for
the run step.

3. **Build** the project with the resolved scheme/configuration:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project "/Users/fayazahmed/Developer/fayazara/mac/Kaze/Kaze.xcodeproj" \
  -scheme "<SCHEME_NAME>" \
  -configuration "<CONFIGURATION>" \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

If the output shows `BUILD FAILED`, stop here, read the `error:` lines, and
help the user fix them. Do not proceed to run a broken build. If the output is
empty or unclear, re-run without the grep filter to get full output for
diagnosis.

4. **Kill every running instance of the app, across all schemes** - not just
   the one being launched. The two schemes produce different executable names
   (`Kaze`, `Kaze Dev`), and leaving an old instance running is confusing
   (duplicate menu bar icons, two event taps fighting over the shortcut):

```bash
killall Kaze 2>/dev/null
killall "Kaze Dev" 2>/dev/null
```

(It's fine if these error because that variant wasn't running. If a new
scheme is added later with a different `EXECUTABLE_NAME`, add its `killall`
line here too - check with `EXECUTABLE_NAME` from step 2.)

5. **Run** the freshly built app using the path resolved in step 2:

```bash
open "<BUILT_PRODUCTS_DIR>/<FULL_PRODUCT_NAME>"
```

## When to Use

- User says "run it", "build and run", "try it out", "relaunch the app"
- After making code changes, when the user wants to see the change live rather
  than just verify it compiles (for compile-only checks, use `build-kaze`
  instead)

## Notes

- DerivedData paths are specific to this machine/checkout and can change
  between clean builds - always resolve `BUILT_PRODUCTS_DIR` via
  `-showBuildSettings` (step 2) rather than assuming a fixed path.
- Kaze is a menu bar app (`LSUIElement`), so no Dock icon or window appears on
  launch unless onboarding hasn't been completed. Look for its menu bar icon.
- The shortcut needs Accessibility permission. A rebuilt app with a new code
  signature may need to be re-enabled in System Settings > Privacy & Security >
  Accessibility before the shortcut works again.
- Logs: `log stream --predicate 'subsystem == "com.fayazahmed.Kaze"' --level debug`
