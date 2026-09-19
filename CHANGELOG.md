# Changelog

All notable changes to Bassline are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

Focus: power draw while visualizing. The previous renderer rasterized a
full-width bitmap on the CPU and uploaded it to the compositor on every frame.

### Changed

- **Renderer moved to Metal.** `WaveView` is now backed by a `CAMetalLayer`
  and all three styles are drawn by one fragment shader from the band data:
  no CPU rasterization, no per-frame bitmap upload, one draw call per frame.
  The shader is compiled from source at startup (no Metal toolchain needed in
  the Command Line Tools). `RenderResources` (cached CG gradients, sprites and
  colors) is gone
- Frame rate capped at 30 fps by default (was 60); Low Power Mode now caps at
  20 fps (was 30)
- Always drawn at 1x backing scale (was 2x outside Low Power Mode): 4x fewer
  pixels per frame, no visible difference on a soft-edged strip
- A frame is rasterized only when a band, peak, bass level or the fade alpha
  changed by more than a sub-pixel threshold; unchanged frames skip the redraw
  and the compositor pass entirely
- Fade and peak-fall speeds are time-based, so the lower frame rate does not
  change how the visualizer feels

---

## [0.2.0] — 2026-09-18

Focus of this release: low CPU and GPU cost, and a real-time safe audio path.

### Added

- **Low Power Mode**: caps the visualizer at 30 fps and draws at 1x backing scale
- Idle shutdown: once audio stops and the visualizer fades out, the display link
  is invalidated and the overlay window is ordered out, so a paused track costs
  no CPU and no compositor work. A half-second watchdog brings it back when the
  analyzer produces frames again
- Status line in the menu: not running / connecting / permission needed / idle /
  visualizing, with an **Open Privacy Settings** button when the audio capture
  grant is missing
- `BasslineCore` library target holding the pure DSP, with unit tests for band
  mapping, the frame ring (including a concurrent writer/reader tear test), the
  analyzer and the render-side reader
- Listener on the aggregate device sample rate, so a 48 kHz to 44.1 kHz switch
  rebuilds the band mapping instead of silently drifting
- `.gitignore`, `LSMinimumSystemVersion`, and a stable code-signing identity in
  `build_app.sh` so the audio permission survives rebuilds

### Changed

- **Audio thread is now real-time safe.** The IO callback no longer allocates,
  locks or logs: all scratch buffers are allocated once, the bin-to-band table
  is held as raw memory, and frames are published through a lock-free
  single-producer ring with a seqlock instead of an `NSLock` shared with the
  render thread
- **Spectrum is now in dB.** Per-frame max normalization is replaced by a fixed
  −68 dB to +6 dB window, a 3 dB-per-octave tilt and a slow automatic gain, so a
  quiet passage no longer renders at the same height as a drop
- **All Core Graphics shadow blur removed.** Glow is layered strokes and a
  cached radial sprite; gradients and alpha-adjusted colors are cached and
  reused between frames
- Frame rate capped at 60 fps (30 in Low Power Mode) instead of following
  ProMotion to 120 Hz
- Band history, peaks and aurora sparks moved to fixed-size storage, so the
  render loop allocates nothing
- Settings changes are delivered through Combine instead of a 0.25 s polling
  timer that was never invalidated
- Wallpaper sampling runs every 60 s instead of 30 s, only when the tint is Auto
- Analyzer hop size raised from 256 to 512 samples (half the FFT work for no
  visible difference at 60 fps)
- Retry loop no longer blanks a working overlay, gives up after 15 attempts, and
  reports the reason instead of failing silently

### Fixed

- Exclusivity violation in the stereo downmix: `vDSP_vadd` received the same
  array as both input and output
- Display link invalidated a full screen-width layer on every tick even when
  nothing was drawn
- Force unwraps that could crash: `NSScreen.screens.first!` with no display
  attached (lid closed, external display asleep) and two `CGGradient(...)!`
- `NSScreen.displayID` cast an `NSNumber` directly to `UInt32` and silently
  returned 0
- Strip height stored for a large display stayed oversized on a smaller one
- Property listeners could be removed with a different address than the one they
  were registered with
- Bundle identifier and logging subsystem corrected to `com.NorEliYehShi.bassline`

---

## [0.1.0] — 2026-09-17

### Added

- Core Audio process tap targeting Spotify's PID via
  `CATapDescription(stereoMixdownOfProcesses:)` — Spotify keeps playing, no
  virtual audio driver needed
- Private aggregate device with drift compensation; rebuilds automatically when
  the default output device changes (for example switching to AirPods)
- `SpotifyWatcher`: observes `NSWorkspace` launch and terminate notifications and
  retries tap attachment until Spotify's audio process object is available
- FFT spectrum analysis (1024-sample Hann window) mapped to 48 log-spaced bands
  from 40 Hz to 18 kHz, with attack/decay smoothing and silence detection
- **Wave** style: smooth spectrum curve with gradient fill and glow
- **Dots** style: 48 glowing dots that track each band and leave a short trail
- **Aurora** style: drifting energy blobs with onset sparks
- Fade-in and fade-out when music starts and stops
- Borderless click-through overlay window, level `.statusBar`, visible on all
  Spaces and above full-screen apps
- Menu bar controls: screen picker, style, color tint, opacity, height, sync
  offset and Launch at Login
- Latency compensation from the active output device, so Bluetooth headphones
  stay in sync
- Settings persisted to `UserDefaults`
- `scripts/build_app.sh` and `scripts/run.sh`
