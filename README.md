# Bassline

A macOS menu bar app that visualizes Spotify's audio output as a subtle,
semi-transparent animated strip along the bottom edge of your screen.

![style: wave, dots or aurora](https://img.shields.io/badge/style-wave%20%7C%20dots%20%7C%20aurora-lightgrey) ![platform: macOS 14.2+](https://img.shields.io/badge/platform-macOS%2014.2%2B-blue)

## What it does

- Captures Spotify's audio output directly with a Core Audio process tap. No
  virtual audio driver, and Spotify keeps playing normally
- Draws a real-time spectrum visualizer (wave, dots or aurora) at the bottom of
  the screen you choose
- Reacts only to Spotify. Other apps playing audio are ignored
- Click-through: never steals focus or blocks the windows below
- Compensates for output device latency automatically, so Bluetooth headphones
  stay in sync
- Costs nothing when paused: the renderer shuts down completely and the overlay
  leaves the compositor until audio comes back

## Requirements

- macOS 14.2 or later
- Spotify (Mac desktop app)
- Swift 5.10+ / Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```bash
git clone <repo-url>
cd Bassline
bash scripts/run.sh
```

On first launch macOS asks for **System Audio Recording** permission. Grant it,
then play something in Spotify.

Build the app bundle without launching:

```bash
bash scripts/build_app.sh   # output: build/Bassline.app
```

Verify the DSP core:

```bash
swift run -c release BasslineCheck
```

This covers band mapping, the lock-free frame ring (including a concurrent
tear test), the analyzer and the render-side reader, and it asserts that the
audio accumulation loop always terminates. It uses plain assertions instead of
XCTest, so it works with the Command Line Tools alone.

`swift test` runs the same checks as XCTest, but XCTest ships only with full
Xcode. With Command Line Tools only it fails with
`unable to resolve module dependency: 'XCTest'` — use `BasslineCheck` instead.

### Keeping the audio permission across rebuilds

Ad-hoc signing gives the app a new identity on every build, so macOS asks for
the permission again each time. Create a self-signed code signing certificate
named `Bassline Self Signed` in Keychain Access (Certificate Assistant > Create
a Certificate, type "Code Signing", identity type "Self Signed Root") and the
build script will use it. Override the name with `SIGN_IDENTITY=...`.

## Controls

Click the waveform icon in the menu bar:

| Setting | Range | Default |
|---|---|---|
| Screen | any connected display | main display |
| Style | Wave / Dots / Aurora | Wave |
| Color | Auto (adapts to wallpaper) / Light / Gray / Dark / Accent | Auto |
| Opacity | 10% – 100% | 60% |
| Height | 40 px – half the screen height | 80 px |
| Sync offset | -300 – +300 ms | 0 ms |
| Low Power Mode | on / off | off |
| Launch at Login | on / off | off |

The menu also shows the current state (waiting for Spotify, connecting,
permission needed, idle, visualizing).

## How it works

```
Spotify → Core Audio process tap (CATapDescription)
       → private aggregate device + IOProc (512-frame buffer)
       → ring buffer → vDSP FFT (1024 samples, Hann window, 512-sample hop)
       → 48 log-spaced bands (40 Hz – 18 kHz), dB scaling + tilt + slow AGC
       → lock-free frame ring, timestamped
       → presented at (display time − output latency − sync offset)
       → CADisplayLink → Metal fragment shader (CAMetalLayer)
       → borderless click-through NSWindow at the bottom of the chosen screen
```

Output latency comes from the active output device (device and stream latency,
safety offset, buffer size), so Bluetooth headphones stay in sync on their own.
The Sync offset slider fine-tunes on top of that.

### Performance notes

The audio path is real-time safe: the IO callback allocates nothing, takes no
lock and logs nothing. Frames reach the renderer through a lock-free
single-producer ring, so the render thread can never block the audio thread.

The strip is drawn on the GPU: one fullscreen triangle and one fragment shader
render the whole visualizer procedurally from the band data, so per frame the
CPU copies a few kilobytes of uniforms and encodes a single draw call. Nothing
is rasterized on the CPU and no bitmap is uploaded; the compositor receives a
GPU texture directly. The shader is compiled from source at startup, so no
Metal toolchain is needed to build.

The strip is drawn at 1x backing scale and capped at 30 fps (20 fps in Low Power
Mode); the bands are smoothed, so neither Retina resolution nor 60 fps is visible
on it. A frame is rendered only when a band, peak or the fade level actually
moved, so a sustained note or quiet passage costs nothing beyond the display
link tick.

When playback stops and the visualizer fades out, the display link is
invalidated and the window is ordered out, so an idle Bassline does no work at
all beyond a half-second watchdog.

## Project layout

```
Sources/
  Bassline/
    App/        BasslineApp.swift      entry point, AppDelegate
                AppStatus.swift        user-visible state
                Log.swift
    Audio/      ProcessTap.swift       Core Audio tap + aggregate device
                SpotifyProcess.swift   watch Spotify, resolve its audio object
                AudioEngine.swift      render-side handle on the analyzer
                CoreAudioHelpers.swift
    UI/         OverlayWindow.swift    borderless window, idle/wake control
                WaveView.swift         frame state, display link, CAMetalLayer
                MetalRenderer.swift    GPU pipeline + fragment shader source
                MenuView.swift         menu bar popover
                BackdropSampler.swift  wallpaper luminance sampler
    Settings/   Settings.swift         UserDefaults + login item
  BasslineCore/                        pure DSP, unit tested
    SpectrumAnalyzer.swift             real-time safe FFT and band mapping
    SpectrumFrameRing.swift            lock-free SPSC frame ring
    SpectrumReader.swift               latency-compensated frame lookup
    BandMapping.swift                  precomputed bin-to-band table
  CBasslineAtomics/                    atomic load/store helpers
Tests/BasslineCoreTests/
Resources/Info.plist
scripts/build_app.sh, scripts/run.sh
```

## Permissions

Bassline requests only `kTCCServiceAudioCapture` (System Audio Recording). No
microphone access, no network, no file access outside its own bundle. Audio is
analyzed in memory and never recorded or stored.

## Limitations

- One screen at a time
- Spotify only, not system-wide audio
- Not sandboxed, not App Store ready
