# USB sync progress beside the drive

The selected option 1 puts a short progress group immediately left of the stable drive control.
The phase and current step's item count sit above a 200-point, 6-point blue bar; Cancel stays to
the right of the drive. The drive name and button size no longer change with each step.
Clicking the drive opens the existing progress details and log.

Counts belong to the current step, not the whole sync. Saving playlists, finishing disk writes,
and checking the USB use an indeterminate bar without a stale track count. The CLI now emits a
checking phase before its final verification. Successful completion restores the normal drive
name and Sync state; failed or cancelled jobs retain details at the drive control.

The sidebar keeps neutral capacity, last-sync time, drive selection and Eject. There is no second
USB progress card under Up Next. Library analysis jobs retain their existing card.

## Verification — option 1, October 11

- Debug build and signature verification passed; 40 targeted tests in 5 suites passed.
- Native QA used an isolated two-track library and the disposable DH_SYNC disk image.
- Cancel stopped the job before execution; the USB manifest SHA-256 was unchanged:
  `34d281fccb626223286e23721dc071840fe6389d3fe3eab63fa66dcd1e73c03b`.
- A second native sync ran the real engine, updated analysis/metadata/database, committed, and
  verified clean (`pending: 0`). Existing audio was retained (`copied: 0`). Independent CLI
  validation returned “OK — no problems found on DH_SYNC.”
- A test-only wrapper emitted a 6-of-11 copying sample and paused real CLI output at saving and
  checking so the short-lived states could be inspected. Those pauses and sample counts are
  absent from the production bundle; this was not an eleven-track copying benchmark.
- Native clicks verified the details popover, clear finishing labels, disabled Sync after completion,
  and visible phase/bar/drive/Cancel controls at 1440×900 and minimum 1080×900.
- The first visual comparison found phase/count text too small. It was raised to the toolbar's
  callout size and compared again against the selected design. See the project-root design QA report.

Evidence: [implemented toolbar](../images/library-evidence/58-progress-beside-drive-refined.png),
[focused comparison](../images/library-evidence/59-progress-toolbar-refined-comparison.png),
[minimum width](../images/library-evidence/61-progress-compact.png),
[saving playlists](../images/library-evidence/62-progress-saving.png),
[checking USB](../images/library-evidence/63-progress-checking.png),
[completion](../images/library-evidence/64-progress-completed.png),
[engine and validation](validation-evidence/beside-progress-native-qa.log),
[tests](validation-evidence/beside-progress-tests.log),
[build](validation-evidence/beside-progress-build.log).

## Sidebar helper messages

Helper messages were attached to the whole split view and sized to their full text width, so long
messages crossed the sidebar divider. They now anchor above the drive footer, using its sidebar width
as the constraint. Long text wraps vertically inside a rounded card with 12-point side margins.
There is no fixed footer-height offset. Existing message content and dismissal timing are preserved.

Build/signature verification passed. An offscreen native SwiftUI render using SidebarNotice and its
footer placement verified the reported capacity message at 200, 240 and 320-point sidebar widths.
[Width/placement evidence](../../images/library-evidence/44-sidebar-notice-wrap.png). The regular app
was rebuilt and reopened.

## Neutral drive capacity

The native progress indicator's secondary tint appeared almost black against the dark footer.
Capacity now uses an explicit gray filled capsule on a dimmer track. It always represents the
fraction of space actually used; blue remains at the toolbar for sync progress and actions, and
capacity warnings retain their separate status message. The fraction is clamped and exposes its
percentage to accessibility.

Build/signature verification passed. The reopened regular app visibly shows 311 MB / 507.5 MB
as a roughly 61% gray fill. [Screenshot](../images/library-evidence/50-gray-drive-capacity.png).

## Installed build

The verified production bundle was installed at `build/Deckhand.app` and reopened.
Only the regular Deckhand process remains running. The QA image was ejected, and the
production CLI was compared byte-for-byte with the staged build (no QA wrapper).
[Reopened regular app](../images/library-evidence/65-progress-regular-app.png).
