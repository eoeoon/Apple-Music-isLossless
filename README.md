# isLossless

isLossless is a quiet macOS menu bar app for showing the detected Apple Music playback format and whether the current Mac output format is aligned with it.

## Design principles

- Stay in the menu bar.
- Show the current playback format in the simplest possible form.
- Use the system San Francisco font and native macOS controls.
- Avoid custom ports, web UIs, and unnecessary decoration.
- Distinguish the detected Apple Music track format from the Mac output device format.

## Menu bar behavior

The menu bar item combines a status marker, compact text, and an icon:

- Matching source and output sample rate: green marker.
- Current source sample rate is higher than output: yellow marker.
- Current source sample rate is lower than output: green outline marker.
- Detection failure: red marker.
- Transitioning, detecting, or missing source/output sample rate: no marker.

The text uses these rules:

- Lossless format: `44.1kHz`, `96kHz`, etc.
- Lossy Apple Music format: `AAC 256kbps`
- Detecting or unavailable while playback is active: `—`
- Idle, not playing, paused without a cached format, or Apple Music not running: inactive icon.

The menu also shows:

- Current track title and artist, when available.
- Detected Apple Music format.
- Mac output device format.
- A prediction indicator for upcoming output changes.
- Playback status.
- A manual refresh action for forcing a short Apple Music log scan.

## Implementation notes

The app is structured as a Swift Package with a pure Swift core module and a macOS menu bar executable.

- `IsLosslessCore` contains formatting and log parsing logic that can be tested outside macOS.
- `isLossless` contains the native macOS menu bar shell.
- Apple Music track metadata is read through AppleScript.
- Apple Music source format hints are read from recent unified log messages and preload events.
- The current Mac output device format is read separately through CoreAudio.
- Output switching uses CoreAudio and is coordinated with preload predictions.
