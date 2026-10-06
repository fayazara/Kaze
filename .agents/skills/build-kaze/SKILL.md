---
name: build-kaze
description: "Build the Kaze macOS app using xcodebuild. Use this skill whenever the user asks to build, compile, or check if the Kaze project compiles successfully. Also use it when the user asks to fix build errors, verify changes compile, or run a debug build."
---

# Build Kaze

This skill handles building the Kaze macOS application via `xcodebuild`.

## Build Command

Run this exact command to build the project:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project "/Users/fayazahmed/Developer/fayazara/mac/Kaze/Kaze.xcodeproj" \
  -scheme "Kaze Dev" \
  -configuration Debug \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

The first build after a clean checkout compiles MLX (C++ and Metal shaders)
and takes several minutes. Use a generous tool timeout (~10 min).

## Interpreting Results

- **BUILD SUCCEEDED** -- the build passed, report success to the user.
- **BUILD FAILED** with `error:` lines -- read each error, identify the source file and line, and help the user fix them. After fixing, re-run the build to verify.
- If the output is empty or unclear, re-run without the grep filter to get full output for diagnosis.

## When to Build

- After making code changes, if the user asks to verify they compile
- When the user explicitly says "build", "compile", or "check if it builds"
- After fixing build errors, to confirm the fix worked

## Notes

- The project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
  `MemberImportVisibility`. Code that runs on audio/capture queues must be
  marked `nonisolated`, and every file must import the modules whose members
  it uses (e.g. `import Speech` to use `AssetInventory.Status` cases).
