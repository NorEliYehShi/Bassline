# Bassline

Version 0.2.0 | 2026-09-19 | Author: NorEliYehShi | License: MIT

Bassline is an unofficial macOS menu bar visualizer for Spotify audio. It
renders a subtle, animated spectrum strip along the bottom of the selected
screen.

## Requirements

- macOS 14.2 or later
- Spotify for macOS
- Swift 5.10+ and Xcode Command Line Tools

## Run

```bash
git clone https://github.com/NorEliYehShi/Bassline.git
cd Bassline
bash scripts/run.sh
```

On first launch, grant **System Audio Recording** permission. Bassline analyzes
Spotify audio in memory only. It does not record, store, or transmit audio.

## Build

```bash
bash scripts/build_app.sh
```

The app bundle is created at `build/Bassline.app`.

## License

Copyright (c) 2026 NorEliYehShi. Released under the [MIT License](LICENSE).

Bassline is an independent project and is not affiliated with, endorsed by, or
sponsored by Spotify.
