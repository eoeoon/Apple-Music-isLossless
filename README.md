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

- Detected format: `24비트 96kHz`
- Sample rate only: `96kHz`
- Detecting: `확인 중`
- Idle, not playing, or unavailable: `—`

## Implementation notes

The app is structured as a Swift Package with a pure Swift core module and a macOS menu bar executable.

- `IsLosslessCore` contains formatting and log parsing logic that can be tested outside macOS.
- `isLossless` contains the native macOS menu bar shell.
