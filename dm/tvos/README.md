# D2R TV — experimental Apple TV port

[中文移植与实测记录](PORTING.zh-CN.md)

This branch is a reviewable prototype, not a release-ready upstream PR. Device tests were performed on base ea86e79; the changes apply to b94670c, but the newer base has not been rebuilt or retested on-device. Remaining integration work includes bilingual comments/docs, routing new on-screen text through the shared localization table, and broader regression testing.


This adds `DmTV` to the existing generated `dm/ios/DmIOS.xcodeproj`.
No new clone and no changes to the existing iOS target/configurations. Run
`python3 dm/tvos/add_target.py` again if the normal iOS generator replaces the project.
The script is idempotent and adds a shared Release Run scheme.

## Build / install / run

From the repository root (Xcode 27 with tvOS SDK and the existing signing account):

```sh
TVOS_TEAM_ID="<YOUR_TEAM_ID>" TVOS_BUNDLE_ID="<YOUR_BUNDLE_ID>" python3 dm/tvos/add_target.py
xcodebuild -project dm/ios/DmIOS.xcodeproj -scheme DmTV \
  -configuration Release -sdk appletvos \
  -destination 'id=<APPLE_TV_UDID>' \
  -derivedDataPath /tmp/d2r-tv-build -allowProvisioningUpdates
xcrun devicectl device install app --device <APPLE_TV_UDID> \
  /tmp/d2r-tv-build/Build/Products/Release-appletvos/DmTV.app
xcrun devicectl device process launch --device <APPLE_TV_UDID> \
  --console --terminate-existing org.example.d2rmobile.tv
```

Alternatively open the existing Xcode project, select DmTV and the test Apple TV, then Run.
Set TVOS_TEAM_ID and TVOS_BUNDLE_ID to your own development team and unique app identifier before running add_target.py. The sharing package contains no personal signing settings.
The tvOS app has a separate bundle identifier and no iOS-only entitlements.

## Implemented

- Existing generated host/gfx/Metal sources and embedded game code, shared gamepad adapter.
- Separate UIKit/CAMetalLayer scene frontend, 16:9 game resolution, text input bridge.
- Basic foreground/background hooks for controller reset, audio, guest clock and renderer.
- A15 CPU baseline, device family 3, tvOS 26 minimum, physical tvOS build.
- Crash handler alternate-stack APIs excluded only on tvOS (unavailable in its SDK).
- Product-only metadata cleanup before signing; original game resources untouched.
- Resource readiness gate; does not launch the guest with missing data/shaders.

## Measured on 2026-10-14

Signed build and installation succeeded on the test Apple TV, AppleTV14,1 (A15).
First launch trapped in UIKit's no-scene-lifecycle check. Added scene manifest and
SceneDelegate; second launch remained running with no observed process termination.
Device log reports `Apple A15 GPU`, `supportsBCTextureCompression = 0`, and a valid
Metal 4 command queue with no error. Siri Remote is not an extended controller.

Further device testing reached actual game rendering and the character-creation navigation path.
The user observed the Diablo II and loading screens. The diagnostic BC fallback launch
was then killed by tvOS with `per-process-limit` (JetsamEvent 2026-10-14 19:50:35).
This is **not yet a playable/stable game milestone**. The completed fast-preset ASTC pack subsequently passed validation and reached the
character selection screen without the previous loading-stage kill. A 1920×1080
frame was captured on-device. Actual gameplay and long-session stability remain unverified.

All 6927 base shaders and 285 framebuffer-fetch variants compiled successfully for
tvOS and were transferred. All 46 original RomFS files match their source sizes
(8,973,547,258 bytes). Full shader content validation passed on-device.
A validation-cache abort caused by oversized NSUserDefaults storage was fixed by
moving stamps to an ordinary plist in Caches. The subsequent launch reached rendering.

## Remaining work / limits

- ASTC is deployed (27,215 textures; archive 994,556,849 bytes). Retest actual gameplay
  and longer-session memory; this first functional pack uses the fast encoding preset.
- Extended 8BitDo controller detection was verified, but gameplay input is unverified.
- Saves are currently in Caches and purgeable. Durable save sync/recovery,
  save-before-background, audio interruptions and controller reconnection need testing.
- Native ZR behavior is retained; the optional free-town-portal shortcut is disabled.
- Keep DerivedData outside cloud-synced folders: file-provider Finder attributes can
  reappear after cleanup and break signing. A clean temporary installation copy works.
- `DM_TV_ALLOW_BC_FALLBACK=1` is diagnostic only; it bypasses the ASTC gate and has
  already exceeded this Apple TV's per-process memory limit during initial loading.

## Resource bring-up (follow-up)

The new shell validates original archive sizes, the tvOS shader chain, complete
shader manifests with SHA-256, and the A15 ASTC archive before starting the guest.
Validation runs on a worker queue to avoid blocking the scene launch watchdog.
Successful content checks are cached against path/size/mtime/expected SHA-256.

Compile base shaders with `build_shaders.py` and framebuffer-fetch variants with
`build_variants.py`, using the existing Mac `b-<DMSH_CHAIN>` MSL cache as input.
Both take SOURCE OUTPUT --toolchain PATH; outputs live in OUTPUT/b-<CHAIN>.
The toolchain is Apple's downloaded Metal.xctoolchain, and the target is explicitly
`air64-apple-tvos26.0`. Neither script changes existing iOS shader caches.
Use only the b-<CHAIN> directory for deployment, excluding the sibling module cache.

For A15, use the existing `dm/tools/astc_pack.py` and `casc_overlay.py pack` flow,
then `astc_pack.py finalize`. Run `gen_romfs_overlay.py` with DM_ASTC_PACK pointing
to the finalized pack and a separate tvOS output path (not ios/Gen).

Device paths, relative to org.example.d2rmobile.tv's appDataContainer:

- `Library/Caches/D2R/RomFS/data`: original archives (all original files retained).
- `Library/Caches/D2R/msl/b-<CHAIN>`: tvOS libraries, reflection JSON, tvos-manifest.json,
  and tvos-variants.json. Both base and fetch variants must be complete.
- `Library/Caches/D2R/astc/data`: generated ASTC archive.
- `Library/Caches/D2R/romfs_overlay_astc`: generated index/overlay and pack.json.

Launch with environment `DM_TV_SHOT_SECONDS=60` for one diagnostic frame capture
under `Library/Caches/D2R/frame.png`. It captures a real presented frame through
the existing renderer callback; the log reports the presentation count and file size.
This is a diagnostic switch, not a user-facing upload/download screen.

## Sharing package

Only porting source and documentation are included. Game data, translated shaders, generated game code, textures, saves, app binaries, provisioning profiles, raw logs are excluded. The user-selected AI-generated bow-wearing Diablo icon is included as optional custom artwork, not extracted game art. Supply your own existing generated project and resources. The included custom icon is enabled when Assets.xcassets is present; upstream adoption is at the maintainer’s discretion. Bundle IDs in examples are placeholders; use the same unique ID for build and device commands.
