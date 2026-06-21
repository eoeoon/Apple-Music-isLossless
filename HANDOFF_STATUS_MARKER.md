# Status Marker Handoff

## Context

This handoff is for a future Codex session continuing the macOS menu bar marker work.

The user wants a status marker shown in the menu bar icon/title area. This marker is separate from the existing prediction marker shown near the "Output" row in the menu. Do not confuse these two marker systems.

The requested menu bar layout is:

```text
[marker] + [text] + [icon]
```

The marker should appear to the left of the menu bar text. The existing waveform/logo icon should remain on the right side of the text.

## Important UI Constraint

The current menu bar icon appears to behave like a template image, so macOS automatically adapts it for light/dark mode. The user does not want to lose this automatic light/dark behavior.

Avoid flattening the whole status item into one non-template bitmap if that would make the main icon stop adapting to appearance changes.

Preferred direction:

- Keep the main app icon as a template image where possible.
- Add the marker as a separate drawn element or attributed title prefix if AppKit allows the desired layout.
- If compositing into an image is necessary, preserve template behavior for the main icon or redraw on appearance changes so the icon remains visually correct in light/dark mode.

## Marker Policy

Inputs needed:

- Current track format:
  - sample rate
  - bit depth, if available
  - detection status
- Current output format:
  - output sample rate
  - output bit depth, if available
- Prediction/output-switching transitional state

### C. No Marker While Unstable

Show no marker when the app is in a transitional/uncertain switching state:

- prediction has been applied and is waiting for confirmation
- prediction/current format confirmation is still in progress
- output sample rate or physical format is actively being adjusted
- current sample rate is not yet finalized

This rule has priority over normal match/mismatch markers.

### D. Detection Failure

If detection failed, show a red filled circle marker.

```text
failed -> red filled circle
```

This rule should apply after the transitional no-marker rule.

### A. Sample Rate Matches

If current track sample rate and output sample rate match:

#### A-1. Both Bit Depths Are Available

If both current track bit depth and output bit depth are available:

- Exact sample rate and bit depth match:

```text
green filled circle
```

- Sample rate matches but bit depth differs:

```text
green outline circle
```

#### A-2. Bit Depth Is Missing On Either Side

If the sample rate matches but one or both bit depths are unavailable, compare sample rate only and treat the output as matched:

```text
green filled circle
```

Rationale: when either side does not provide bit depth, bit-depth mismatch cannot be proven. Use sample-rate match as the marker decision.

### B. Sample Rate Mismatch

If current track sample rate and output sample rate do not match:

- Current track sample rate is higher than output sample rate:

```text
yellow filled circle
```

- Current track sample rate is lower than output sample rate:

```text
green outline circle
```

Rationale from user policy: playing a lower sample-rate track through a higher output rate is not a warning state; use the same green outline marker.

## Priority Order

Use this order so states do not conflict:

1. Transitional/adjusting/prediction-confirming state -> no marker
2. Detection failed -> red filled circle
3. Missing current sample rate or output sample rate -> no marker
4. Sample rates match:
   - bit depths available and equal -> green filled circle
   - either bit depth unavailable -> green filled circle
   - both bit depths available and different -> green outline circle
5. Current sample rate > output sample rate -> yellow filled circle
6. Current sample rate < output sample rate -> green outline circle

## Suggested Type Model

Add a pure policy type in `IsLosslessCore` so this can be unit-tested without AppKit:

```swift
public enum MenuBarStatusMarker: Equatable, Sendable {
    case none
    case filled(MarkerColor)
    case outline(MarkerColor)
}

public enum MarkerColor: Equatable, Sendable {
    case green
    case yellow
    case red
}
```

Potential policy function:

```swift
public struct MenuBarStatusMarkerPolicy {
    public static func marker(
        detectionStatus: DetectionStatus,
        currentFormat: AudioFormat?,
        outputSampleRate: Double?,
        outputBitDepth: Int?,
        isTransitioning: Bool
    ) -> MenuBarStatusMarker
}
```

Use tolerance when comparing sample rates. Existing code often works with `Double`; avoid exact floating-point equality. A small tolerance such as `0.5` Hz should be enough unless the repo already has a sample-rate comparison helper.

## Data Sources To Inspect

Likely files:

- `Sources/isLossless/main.swift`
  - `IsLosslessApp`
  - status item/menu bar UI setup
  - `applyState(_:)`
  - `AudioOutputObserver`
  - prediction state callbacks
- `Sources/isLossless/AudioOutputSwitcher.swift`
  - output format read/apply result types
- `Sources/isLossless/PreloadPredictionCoordinator.swift`
  - pending/applied/confirmed prediction state
- `Sources/IsLosslessCore/MenuBarTitleFormatter.swift`
  - existing menu bar text formatting
- `Sources/IsLosslessCore/DetectionStatus.swift`
  - failed/detected/unverified states
- `Sources/IsLosslessCore/AudioFormat.swift`
  - current format model

## Expected Tests

Add pure policy tests under `Tests/IsLosslessCoreTests`.

Required cases:

- transitioning state returns `.none`
- failed state returns red filled
- matching sample rate and matching bit depth returns green filled
- matching sample rate and different bit depth returns green outline
- matching sample rate with missing bit depth on either side returns green filled
- current sample rate higher than output returns yellow filled
- current sample rate lower than output returns green outline
- missing current sample rate or missing output sample rate returns `.none`

## Implementation Notes

- This marker is not the same as prediction pending/matching marker near the menu's "Output" row.
- Do not add polling for this marker. It should update when existing app state or output observer state changes.
- Avoid using Unicode colored circle characters as the final UI if they look inconsistent in the menu bar. A small AppKit-drawn circle is likely better.
- If using an attributed title prefix, verify vertical alignment and spacing in both light and dark mode.
- If using image composition, verify the main icon still changes correctly across light/dark mode.
- If the marker is hidden, the menu bar layout should not leave awkward extra spacing.

## Example Expected States

```text
ALAC 96000/24 playing, output 96000/24 -> green filled
ALAC 96000/24 playing, output 96000/16 -> green outline
ALAC 96000/24 playing, output 44100/24 -> yellow filled
ALAC 44100/16 playing, output 96000/24 -> green outline
AAC or fallback with sample rate 44100, output 44100, no bit depth -> green filled
detection failed -> red filled
prediction applied but not confirmed -> no marker
```
