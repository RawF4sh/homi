# Home assessment module (Person 2)

Pure Dart: no widgets, no plugins, no new dependencies. The controller builds
strict v1 `Finding` and `Measurement` objects from
`lib/shared/models/contracts.dart`. Nothing in this module saves anything or
changes a case revision.

## What is here

| Path | Purpose |
|---|---|
| `application/assessment_controller.dart` | Builds and edits findings; outputs strict v1 `Finding`s |
| `application/fictional_scenarios.dart` | One fictional bathroom and one entrance scenario |
| `domain/ids/id_factory.dart` | ID factory interface (Person 1 owns the real one) |
| `domain/measurement/length_unit.dart` | mm, cm, in with exact integer factors |
| `domain/measurement/measurement_input.dart` | Locale-aware parser and the module-local record of what was typed |
| `domain/measurement/measurement_fields.dart` | Proposed measurement vocabulary, definitions, zero-review rule |
| `domain/image/image_limits.dart` | Server ingestion limits |
| `domain/image/image_validator.dart` | Signature check, HEIF detection, header dimensions, limits |
| `domain/capture/capture_adapter.dart` | Camera abstraction and sealed results |
| `domain/capture/staging_store.dart` | Staging interface and in-memory store |
| `domain/capture/photo_capture_coordinator.dart` | Capture, validate, stage, retake, permission handling |
| `domain/review/finding_review_state.dart` | Typed v1 review states (see below) |
| `domain/review/review_snapshot.dart` | Canonical record of what the resident confirmed |
| `domain/review/finding_review_tracker.dart` | Review transitions and local history |
| `domain/export/export_selection_draft.dart` | Six-image, confirmed-only, reviewed-revision selection; maps to shared `EvidenceSelection` |

Tests are in `test/features/assessment/` with fakes in `fakes/` and a
case-schema helper in `support/`. All image bytes in tests are synthetic
headers; there are no real photos.

## How it connects to the shared models

- **Review state.** The shared `Finding.reviewState` is a validated string with
  no enum, so `FindingReviewState` stays in this module. A test checks its
  wire values against `contracts/v1/case.schema.json`.
- **Findings.** `AssessmentController.toFinding` builds JSON and passes it
  through `Finding.fromJson`, so the output is always a strict v1 object. A
  finding with no observation yet returns null (v1 requires one).
- **Room.** `AssessmentArea.bathroom` and `.entrance` map to the v1 `room`
  values of the same name. `other` is not used yet.
- **Measurements.** Wire values are millimetres; whole values are written as
  integers. The typed text, unit and precision stay in `MeasurementInput`.
  A measurement that was not taken is absent, never zero.
- **Review snapshots.** `ReviewSnapshot.fromFinding` takes a shared `Finding`
  plus the evidence version the resident saw for each image.
- **Export selection.** `SelectedEvidence.toEvidenceSelection` and
  `ExportSelectionDraft.toEvidenceSelections` produce shared
  `EvidenceSelection` entries with `reviewedForExport: true`. Evidence
  revisions are `int`, as `ExportCandidate` assumed.

## Status

189 tests pass in `test/features/assessment/` on Flutter 3.41.5, and
`bash tool/verify_project.sh flutter` passes. Native camera behaviour, phone
builds and widgets are not built or tested yet.

## Decisions needed from teammates

- **Measurement vocabulary** (Persons 1 and 3): the proposed `type` strings
  are `clearOpening`, `thresholdHeight` and `curbHeight`. The controller
  rejects any other type until this is agreed.
- **Room mapping** (Person 1): confirm the direct `AssessmentArea` to
  `Finding.room` mapping above.
- **ID factory** (Person 1): the real `IdFactory`. `newUuidV4()` in
  `lib/shared/models/case_draft.dart` would satisfy the shared ID rules.
- **Save order** (Person 1): how controller output becomes part of the saved
  case before evidence upload, which requires the finding link to exist.
- **Staging** (Person 1): persistent encrypted storage, backup and deletion
  policy. Until then, `InMemoryStagingStore` loses everything when the app
  closes and the UI must not call it saved.
- **Review history storage** (Person 1): `ReviewEvent` and `MeasurementInput`
  are module-local and must never be added to v1 JSON.
- **Camera package** (Person 1): choose and verify on both platforms,
  including what format an iPhone returns.

## Running

```
dart format lib/features/assessment test/features/assessment
flutter analyze
flutter test test/features/assessment
bash tool/verify_project.sh flutter
```

Use the team's Flutter release (3.41.5). A newer SDK rewrites `pubspec.lock`
and `analysis_options.yaml`.

Changes are left unstaged and uncommitted. A human reviews, stages and commits.
