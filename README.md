# PhoneMirror — macOS (viewer)

See your **iPhone screen on the Mac, over Wi‑Fi**, no cable. This is the Mac half:
it discovers the iPhone over Bonjour, hardware-decodes the stream and shows it,
with rotation and a window shaped to the phone.

The iPhone half (the sender) is a separate repo: **PhoneMirror-iOS**.

## Build & run

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project PhoneMirror.xcodeproj -scheme PhoneMirrorView \
  -configuration Release -destination 'generic/platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/PhoneMirror-*/Build/Products/Release/PhoneMirrorView.app
```

The window sizes itself to the phone's aspect ratio (no black bars). Use the
toolbar buttons to rotate 90° left/right.

## How it works

Bonjour (`_phonemirror._tcp`) → `NWConnection` → `VideoDecoder`
(VideoToolbox, H.264/HEVC, hardware) → `AVSampleBufferDisplayLayer`.

## Notes

- Needs **Local Network** permission on first run (macOS asks; allow it).
- First frame comes from a cached keyframe, so an idle phone screen still shows.
- Video only (no audio), and **view-only** — iOS does not allow third-party apps
  to inject touch input, so remote control is not possible (that is Apple's own,
  region-locked, iPhone Mirroring feature).

MIT licensed.
