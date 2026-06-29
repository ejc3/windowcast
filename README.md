# windowcast

A tiny, scriptable, **window-isolated** macOS screen recorder built on
[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).
It records **only a chosen window's pixels** — never the desktop behind it — and
composites them onto a clean styled backdrop (gradient/solid + padding + rounded
corners + soft drop shadow), the polished look you'd otherwise pay a subscription
for.

No GUI, no Electron, one self-contained Swift binary you can drive from a script.

## Why

- **No background leak.** Recording a window as a screen *region* lets the desktop
  show through the rounded corners and shadow. `windowcast` captures the window's
  actual pixels via `SCContentFilter(desktopIndependentWindow:)`, so the result is
  the window and nothing else — even if it's partially covered or on another space.
- **Looks good by default.** Proportional padding, a subtle gradient, macOS-style
  rounded corners and a soft shadow, all composited live with Core Image.
- **Scriptable.** Match a window by app/title, record for a fixed duration or until
  `Ctrl-C`, and wire it into a demo script next to whatever you're showing off.

## Build

```sh
swift build -c release
# binary at .build/release/windowcast
```

Or single-file, no package:

```sh
swiftc -O Sources/windowcast/main.swift -o windowcast \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreImage
```

Requires macOS 14+.

## Usage

```sh
# list capturable on-screen windows
windowcast --list

# record a window to a styled .mov; Ctrl-C to stop
windowcast --match "Safari" --out demo.mov

# fixed length, fully unattended (great in CI/demo scripts)
windowcast --match "Safari" --out demo.mov --fps 60 --seconds 20
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--match <s>` | — | window owner-app **or** title substring (case-insensitive) |
| `--out <file>` | `windowcast.mov` | output path (`.mov`, H.264) |
| `--fps <n>` | `60` | capture frame rate |
| `--seconds <n>` | — | auto-stop after N seconds (else record until `Ctrl-C`) |
| `--padding <v>` | `3%` | backdrop padding: a point value (e.g. `32`) or `%` of the window's larger edge |
| `--radius <pt>` | `14` | window corner radius |
| `--background <c>` | `#3a3a52,#16161e` | solid `#hex`, or `#top,#bottom` for a vertical gradient |
| `--no-shadow` | off | disable the drop shadow |
| `--list` | — | print capturable windows and exit |

## Permissions

The first run needs **Screen Recording** permission for whatever terminal/app you
launch it from: *System Settings ▸ Privacy & Security ▸ Screen Recording*. macOS
will prompt; grant it and re-run.

## How it works

1. `SCShareableContent` enumerates on-screen windows; the first whose app name or
   title matches `--match` is chosen.
2. An `SCStream` with `SCContentFilter(desktopIndependentWindow:)` captures that
   window at native resolution.
3. Each frame is composited with Core Image — rounded-corner mask over a soft
   blurred shadow over a gradient backdrop — and written to an H.264 `.mov` via
   `AVAssetWriter`.

## License

MIT — see [LICENSE](LICENSE).
