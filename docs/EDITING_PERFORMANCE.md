# Native editing and table follow-up

## Scope and causes

This follow-up addresses [#24](https://github.com/ashtree74/PreviewMD/issues/24)
and [#27](https://github.com/ashtree74/PreviewMD/issues/27), based on main
`9b0cae993bfac779689ac9904bbe7727b580007d` (PreviewMD 1.8). The Windows port
remains independent.

The original public synthetic attachment is 126,669 UTF-8 bytes and UTF-16
units, SHA-256
`5dcf69360c09ff74635569eb1fd3551245c14c930be173deb064929f0cf51430`.
It is not copied into the repository.

Native profiling exposed costs that the earlier component harness missed:

- Reading statistics took about 25 ms on `NSTextView.string`, compared with
  about 5 ms on a native Swift string containing the same text. Materializing
  contiguous UTF-8 once in document storage removes repeated foreign-string
  iteration costs while preserving Swift's word and grapheme counting semantics.
- Rich edits updated and recolored the entire native source editor, including
  when its column was hidden. Hidden source work now waits until the column is
  revealed. The view and selection survive; a hidden editor resigns focus and
  cannot publish stale keyboard input.
- Visible rich-to-source updates now replace only the changed UTF-16 range,
  retaining attributes outside it and using incremental highlighting. Ranges
  preserve surrogate pairs. Highlighting also covers the moved suffix of a
  split source line, so rich echoes and Undo cannot retain obsolete syntax
  colors. Fence edits and appearance changes keep full highlighting passes.

## Before and after

Measurements were made on October 6, 2026, on the same arm64 Mac running
macOS 27 (26A428), Apple Swift 6.4, release optimization and SDK 27, with the
real `WorkspaceView` hosted in a 1200 × 760 native window. The baseline is a
clean archive of main using exactly the same profiling test as the patch.
Preferences use a disposable suite; edits stay in memory and never save the
sample. Both editing surfaces explicitly receive native focus before input.

Each mode receives 16 single-character edits with a 60 ms pause between inputs
for deferred work. The pause is excluded. Medians are milliseconds:

| Mode | Input operation, before → after | Document revision, before → after | Revision and forced native display, before → after |
| --- | --- | --- | --- |
| Markdown | 26.87 → 8.56 | 26.88 → 8.57 | 65.68 → 52.35 |
| Preview | 1.71 → 1.81 | 74.12 → 50.21 | 75.30 → 52.02 |
| Split, Markdown input | 27.43 → 8.93 | 27.44 → 8.94 | 74.60 → 59.44 |
| Split, Preview input | 1.71 → 2.03 | 74.13 → 20.07 | 75.83 → 67.25 |

The native input operation includes synchronous AppKit callbacks. Rich input
includes WebKit IPC; the DOM insertion is already fast and is not the principal
gain. Reading statistics directly from native text dropped from roughly 25 ms
to 6.7–6.9 ms, including conversion. Source-only edits performed zero full
preview renders; split source edits performed 16 required visible renders;
rich edits performed zero echo renders.

These are automated native workflow timings, not physical key-to-pixel latency.
The final column includes the harness's explicit SwiftUI layout and AppKit
display pass. Bridge callbacks, scheduling and native painting contribute to
the other timings; cold maximums and p95 are in the raw reports. With 16 samples,
nearest-rank p95 equals the maximum. No timing threshold is enforced in CI.
The issue remains open for the reporter's retest after a public release.

Raw reports: [before](performance/issue-24-before.json) and
[after](performance/issue-24-after.json).

## Reproducing the measurement

Download the [original public sample](https://github.com/user-attachments/files/31117537/large-sample.md)
to a temporary location and verify its checksum. Do not substitute a smaller
fixture. On the Swift Build toolchain used for these measurements:

```bash
previewmd_sdk=$(xcrun --sdk macosx --show-sdk-path)
previewmd_sdk_version=$(plutil -extract Version raw -o - "$previewmd_sdk/SDKSettings.json")
PREVIEWMD_PROFILE_SAMPLE=/private/tmp/previewmd-issue24-large-sample.md \
PREVIEWMD_PROFILE_OUTPUT=/private/tmp/previewmd-editing-profile.json \
swift test -c release --sdk "$previewmd_sdk" \
  -Xlinker -platform_version -Xlinker macos \
  -Xlinker 14.0 -Xlinker "$previewmd_sdk_version" \
  --filter EditingPerformanceProfileTests
```

Run baseline and patch sequentially without competing native tests or builds.
Without both environment variables, the profiling test explicitly skips.

## Expanded tables

The width policy follows jedrzejsieracki's #27 proposal: clamp the expanded
minimum to available width, never below the collapsed readable minimum. Roomy
surfaces retain the 220 px per-column target; narrow surfaces still scroll.
The existing leading-gutter correction remains intact. Available width also
excludes space reserved by classic scrollbars; otherwise their stable gutter
creates a 17 px overflow that is absent with overlay scrollbars. The expansion
action
sits above wide tables, away from their headers, with keyboard focus styling
preserved and at least 4 px clearance from the previous table at the minimum
custom text size. The rounded sizer uses table layout, allowing intrinsic
content such as long unwrapped headers to grow beyond the preferred minimum.
Such content stays fully reachable through the viewport's horizontal scroll.

`RendererAuditTests.testExpandedTableUsesAvailableSpaceWithoutNearFitScrolling`
sweeps 980/1800/520/980 pt windows and 902/560/480/902 pt reading widths using
the showcase's four-column table. It checks the final article width, minimum
and actual column widths, scroll extent, right edge, action/header separation
and collapse, plus a simulated classic-scrollbar inset without changing system
preferences. CI also exercises real classic scrollbars. The six-column
regression retains independent expansion and unchanged Markdown serialization.
Long-header tests check the actual table edge against its rounded sizer and
the viewport after scrolling to the end, in collapsed and expanded states,
at narrow, near-fit, roomy and reserved-scrollbar widths. Adjacent tables at
the 13 px custom text minimum also verify action clearance.

For deterministic policy checks, the test finishes CSS width transitions and
calls the editor's existing public relayout hook: headless WebKit can suspend
animation frames. This does not substitute for the existing transition test.
Set `PREVIEWMD_TABLE_SNAPSHOTS` to a temporary directory to export PNGs and
geometry for visual inspection. The near-fit and roomy tables fit without
scroll; narrow columns remain at least 144 px and scroll as needed.

## Independent review and validation

Two reviewers with no inherited implementation history independently examined
native editing and renderer behavior. They found three regressions: stale
colors on moved source suffixes, inaccessible columns behind a too-small
rounded sizer, and an expansion action overlapping a previous table at small
text sizes. All three added regression tests failed on the original patch,
then passed after the fixes. Both reviewers repeated their review of the
resulting patch and found no unresolved findings in scope. This is independent
agent review, not a GitHub approval submission.

The full local suite passed: 177 XCTest and 5 Swift Testing tests, with the
opt-in profiler explicitly skipped in the normal run. The profiler passed
separately on baseline and patch, and the after report was refreshed after
the independent-review fixes. Nine Python site tests and eight Node signup tests
also passed. The complete ad-hoc bundle and embedded Quick Look extension
passed strict signature verification, contain both arm64 and x86_64, and have
matching current renderer resources. The build script verified macOS 14
deployment and SDK 27 metadata in all four slices. These changes do not create
a new public release; the signed and notarized 1.8 artifacts remain intact.
