# One Sync action

Reviewed the wording with Claude through its read-only CLI on October 11, 2026.

We chose **Sync** for a safe earlier-library USB as well as everyday syncing. Link USB can imply a
missing physical connection. Enable Sync can imply a setting was turned off. Set Up Sync blurs
this case with preparing a new drive. Confirm USB is vague. The user needs to sync, without learning
an ownership state in the toolbar. There is no ellipsis, Review Library label, or dropdown chevron.

A safe older-library USB shows a blue Sync button next to its drive name. It opens a one-time dialog:

> Sync [drive] from this library?
>
> This USB was last synced from an earlier Deckhand library. Deckhand will verify the music, keep
> your playlist selection, and apply the changes below.

The dialog includes selected playlists and the engine's proposed changes. Confirming verifies audio
and ownership continuity, then continues the normal sync for that same active drive. Verification
failure leaves the dialog open, reports the reason, and never starts the sync. Clearing all USB
content still gets the existing destructive confirmation. The toolbar always says **Sync**, including
reading, syncing, unprepared and mismatched drives. Reading and syncing add a small spinner and
disable the action. An actionable drive has a blue Sync button; a fully synced drive shows just its
name and disabled Sync. Clicking Sync on an unprepared drive opens setup; an unsafe mismatch or
read error explains **Can’t Sync [drive]**. These occasional explanations never rename the toolbar action.

Native QA used a separate copied library and the disposable FAT32 DH_SYNC image. With an earlier
library identity and a pending three-star rating for Warmup, Sync showed the one-time explanation
and one planned metadata change. Confirming completed verification and the real sync, retained both
selected playlists, applied the rating, and disabled Sync. Device validation reported no problems.
All 20 dedicated library model tests passed, including the verification-failure continuation check.
The real user USB was not associated or synced.

Evidence: [native completed sync](../images/library-evidence/32-one-time-sync-completed.png),
[test output](validation-evidence/one-time-sync-tests.log).

Follow-up: the fallback **USB Help…** toolbar label was removed. Native QA reproduced the unsafe
mismatch on DJTEST: the toolbar now shows a blue **Sync**, and clicking it opens **Can’t Sync DJTEST**
with an Add Music action, without starting a sync. The explanatory copy was shortened to the
required action. All 23 library model tests passed, including unprepared, mismatched, unreadable,
safe earlier-library and verification-failure USB cases.

Evidence: [same mismatched drive with stable Sync action](../images/library-evidence/36-one-sync-button-mismatched-drive.png),
[model tests](validation-evidence/one-sync-button-tests.log).

The final build was installed and reopened in the regular app, with the QA app closed. Native
evidence shows DECKHAND beside the blue Sync button and the preserved 51-track Mixed in Bongoloco
playlist. The user's added track explains its increase from 50; it was retained.

Evidence: [regular app after installation](../images/library-evidence/37-one-sync-button-regular-app.png).

Launch-state follow-up: a read-only check of the real DECKHAND USB found **zero changes**, zero unknown
tracks, and a complete evaluation. Its saved owner is the earlier Deckhand library UUID; the restored
local library has a different UUID. The blue action was therefore a one-time confirmation, not
pending audio or playlist work. Opening the app does not manufacture changes or automatically sync.

The toolbar now shows **Link library** in orange for that clean earlier-library case. Clicking the
drive name shows the existing explicit confirmation and says **No music or playlist changes**.
Actual work shows **1 change to sync** or **N changes to sync** in orange, including previews of an
earlier library's USB. Clicking the drive name lists the exact changes. Clean matched drives continue
to show only their name and disabled Sync. Sync is disabled with a spinner while both the USB read
and initial status evaluation are pending, preventing an actionable flash before the check finishes.

A regression test syncs an isolated empty playlist, closes/reopens the same library and checks that
it remains clean with no USB writes. It separately checks explicit confirmation for an earlier owner,
the clean state after confirmation, singular/plural real playlist-change counts, and pending changes
surviving another restart. All **24 library model tests passed**.

Evidence: [read-only check](validation-evidence/launch-sync-read-only-check.log),
[regression tests](validation-evidence/launch-sync-tests.log),
[installed toolbar with orange confirmation](../images/library-evidence/38-launch-sync-confirmation.png).
The regular app was reopened with the final build. The real USB was only read; its confirmation was
not accepted or its owner changed during this check.

The subsequent [USB state audit](usb-state-audit-2026-10-11.md) records the final wording, the folder
checkbox staging fix, the difference between the QA and regular libraries, and the latest drive state.

## Setup before association

The toolbar action now reads **Setup** for a readable USB that is new or belongs to another library,
including an older library that can be safely linked. It reads **Sync** after association with the
current library. The existing review/confirmation flow and write protections are preserved.

Three targeted model tests passed for new/mismatched drives, clean/older-library transitions, and
unreadable existing manifests. Native QA confirmed the blue Setup button beside DJTEST / Different
library using an isolated library; no USB write was performed. The regular app was rebuilt and reopened.
[Screenshot](../images/library-evidence/51-different-library-setup.png),
[test log](validation-evidence/setup-label-tests.log).

Follow-up: a safe earlier-library USB with actual pending changes now says **Sync**, matching
its orange **N changes to sync** status. **Setup** remains for an unprepared drive, an unsafe library
mismatch, or an earlier library requiring association without pending changes. The one-time owner
verification still runs before syncing. Regression tests cover both clean association and staged
changes on an earlier-library USB; changing the label does not write to the USB.

The installed regular app was reopened with RATS selected. Native evidence confirms **2,183 changes
to sync** beside the blue **Sync** button. Only the regular Deckhand app remains open; no sync was
started. [Screenshot](../images/library-evidence/54-rats-pending-sync.png),
[31 final model/audio regression tests](validation-evidence/audio-and-sync-label-final-tests.log).
