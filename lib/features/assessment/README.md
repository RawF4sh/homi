# Home assessment module (Person 2)

The live app opens `presentation/live_assessment_screen.dart` from the case
workspace. It combines the partner's guided bathroom/entrance workflow with
native photo capture, private persistence, saved-case hydration, and the v2
assessment/annotation APIs. The fictional demo remains available separately:

```sh
flutter run -t lib/features/assessment/dev/main_assessment_demo.dart
```

Observations and confirmations do not establish clinical need, legal
compliance, structural safety, or benefits eligibility. LiDAR is outside this
first beta; manual entries work on both mobile platforms.

## Implemented boundaries

- `application/live_assessment_session.dart` owns the selected case's encrypted
  local journal and serializes remote writes through Person 1's CaseCoordinator.
  Local drafts restore typed entries, measurements, correction/review history,
  photo staging descriptors, and image-bound marks. Account/session/case guards
  reject late responses. The local assessment envelope has a 512 KiB bound;
  staged image bytes are stored separately under the account's encrypted quota.
- A case saved online at least once can be assessed offline, even while resident
  details have unsaved or unresolved edits. Profile and assessment drafts remain
  separate. Online assessment/photo/annotation writes stay blocked until the
  resident reconciles the case details; guards recheck immediately before
  dispatch. First offline opening uses cached canonical values without inventing
  original-entry metadata, and preserves known remote originals for unchanged
  measurements when reconnecting. New cases need their first online save before
  assessment; previously saved photo downloads need a connection.
- `application/native_capture_adapter.dart` uses the camera package with audio
  disabled. iOS import uses a PHPicker file representation, avoiding an
  unbounded full-resolution UIImage before processing. Android uses the system
  photo picker. Imported photos have unknown capture time; camera photos carry
  the device-clock capture time.
- `PrivateMediaPlatform.swift` and `PrivateMediaPlatform.kt` normalize
  orientation, decode to a maximum 2048-pixel edge, and emit JPEG at quality 85
  without inherited EXIF/GPS metadata. Inputs and decoded dimensions are
  bounded. iOS processing is serialized and uses complete file protection and
  backup exclusion. Android private storage uses `noBackupFilesDir`.
- `presentation/photo_privacy_screen.dart` lets the resident crop or place
  opaque black covers before upload. Edits alter the encoded pixel data. No
  image is written back into the resident's photo library.
- Canonical v1 findings still contain only the existing schema fields. The v2
  atomic save stores original typed measurement text, units, method/provenance,
  and review metadata alongside the case. The server records actor, time and
  correction history. Legacy values with no original input remain explicitly
  unknown; stale metadata from older clients forces review instead of being
  presented as the original value.
- Live annotations are created only on downloaded sanitized images. The v2
  sidecar binds visible boxes and labels to the exact evidence revision, hash,
  dimensions and top-left normalized coordinates. Hidden/stale boxes are not
  sent for rendering. The private export screen displays and explicitly reviews
  saved photo/mark pairs; v2 PDFs render those reviewed marks.
- Lost upload responses never treat a revision increment as proof of this
  device's upload. The staged photo remains until the resident sees the saved
  photo and explicitly chooses a version. Atomic assessment saves retain their
  mutation IDs and recover by matching the server's request-hash receipt.
  Different local/cloud findings require an explicit choice before another write.
- Interrupted Android picker results have no durable case/account receipt and
  are discarded with a retry notice. Already staged photos and typed draft
  content are retained. This is an intentional retry boundary, not automatic
  process-death import continuation.

## Verification and remaining device gates

`flutter test test/features/assessment` exercises fictional inputs, controller
hydration, correction history, encrypted staging isolation, concurrency,
uncertain upload recovery, and accessibility/widget flows. Shared client and
backend v2 contract tests cover the wire boundary. Unit fixtures do not prove
native image or permission behavior.

Before a resident beta, complete physical iPhone and Android runs for:

1. Camera denial/re-enable, no camera, capture cancellation, background/lock,
   incoming interruption and rapid account/case changes.
2. JPEG EXIF orientations 1–8, HEIC import (including cloud-backed Photos),
   large panorama rejection/downsampling and metadata inspection of output.
3. Exact opaque-redaction coverage and crop coordinates in portrait/landscape;
   confirm private details cannot be recovered from the uploaded image.
4. Restart while typing, staged-photo restoration, lost upload responses and
   another device replacing the same evidence.
5. Saved box/label placement on the exact sanitized photo, persistence across
   devices, explicit export review and actual generated PDF overlays.
6. VoiceOver/TalkBack, large text, permission settings, device storage exhaustion,
   complete file protection on lock, backup exclusions and sign-out deletion.
7. Resident-owned device signing/install and share-sheet cleanup. Simulator
   compilation does not replace these checks.

No accuracy claims are made for automated hazard detection or LiDAR scanning.
Changes remain unstaged and uncommitted for the user's review.
