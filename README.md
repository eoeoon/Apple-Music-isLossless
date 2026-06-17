# isLossless

isLossless is a quiet macOS menu bar app for showing the detected Apple Music playback format, such as `24비트 96kHz`.

## Design principles

- Stay in the menu bar.
- Show the current format in the simplest possible form.
- Use the system San Francisco font and native macOS controls.
- Avoid custom colors, custom ports, web UIs, and unnecessary decoration.
- Distinguish the detected Apple Music track format from the Mac output device format.

## MVP behavior

The menu bar title uses these rules:

- Lossless format: `ALAC 24비트 96kHz`
- Lossy Apple Music format: `AAC 256kbps`
- Format without codec: `24비트 96kHz` or `96kHz`
- Detecting or unavailable while playback is active: `—`
- Idle, not playing, paused without a cached format, or Apple Music not running: `isLossless`

The menu also shows:

- Current track title and artist, when available.
- Mac output device name and output sample rate.
- Playback status.
- A manual refresh action for forcing a short Apple Music log scan.

## Implementation notes

The app is structured as a Swift Package with a pure Swift core module and a macOS menu bar executable.

- `IsLosslessCore` contains formatting and log parsing logic that can be tested outside macOS.
- `isLossless` contains the native macOS menu bar shell.
- Apple Music track metadata is read through AppleScript.
- Apple Music source format hints are read from recent unified log messages.
- The current Mac output device format is read separately through CoreAudio.
