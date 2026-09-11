# Shared contracts v1

These files define the first Flutter/backend handoff. The schemas use JSON Schema 2020-12. Configure a full validator to assert `format` checks when adopting one; the dependency-free Dart tests cover the subset currently used here.

- `case.schema.json`: case/profile, reviewed findings, and measurements. Required nullable fields use explicit `null` for unknown. Zero and false are known values. `ownerConsentReported` records an answer, not verified permission. Evidence IDs refer to private evidence records; the fixture does not contain real photos.
- `match.schema.json`: explained results returned by the matcher/API. The Dart models validate structure and source references; they do not evaluate eligibility. `evaluationDate` is an explicit input to the server's policy evaluation, while `evaluatedAt` records when it ran. `recheckAfter: null` means the cache cannot establish freshness. Rule updates can invalidate a result earlier than its deadline.
- `match-request.schema.json`: authenticated saved-case request with case ID and expected revision; no client-supplied owner, policy, profile or clock.
- `case-read-request.schema.json`: authenticated case reload by ID, returning the current `case.schema.json` snapshot so an uncertain answer save can be recovered without guessing its new revision.
- `api-error.schema.json`: safe API error envelope and supported HTTP/error-code pairs. Client messages come from local constants, not raw server details.
- `packet-request.schema.json`: authenticated draft-preparation request selecting a program and a retry key; the server selects rules and loads the saved case.
- `packet.schema.json`: implemented draft-only checklist response. Unknown form/mapping/storage fields remain null until verified or generated. A draft is never proof of submission or approval.
- `form-answers.schema.json`: separate case/form-bound administrative answers, server-owned review provenance, independent answer revision and explicit freshness. This is not a clinical, consent or signature record.
- `form-answers-read-request.schema.json` and `form-answers-save-request.schema.json`: owner-scoped reads and full replacements; saves require expected case/answer revisions and full form context. Every successful save advances the case revision to invalidate old results.
- `fixtures/packets.json`: three fictional saved checklists corresponding to the case/match scenarios. They contain no official forms or real evidence files.
- `fixtures/scenarios.json`: three prewritten, entirely fictional scenarios. The example route checks only `Demo City` and `Example Plan`. These values are teaching data with no real program sources, intake, or benefit policy. No live matcher, backend, or PDF generator is included in the fixtures.

The Dart boundary in `lib/shared/models/contracts.dart` rejects unsupported schema versions, missing/extra fields, invalid types, dates and enums, and inconsistent references. Lists are immutable after parsing. The asset adapter in `lib/shared/services/demo_scenario_service.dart` reads the shared JSON for the first UI demo.

Fixture dates are deliberately fixed for repeatability. At or after their recheck deadline they are stale; tests provide explicit times, and a UI showing them should retain the demo label rather than calling them current program advice.

Run `flutter test test/contracts` from the application root. These tests check the fictional fixture handoff, unknown/zero/false handling, malformed data, source references, and case/date freshness boundaries. They do not validate any real program rule.

`flutter test test/services` checks the request/error schemas and mobile clients. Packet parsing also rejects duplicate checklist/evidence IDs and unsafe storage references; the client checks attachment membership against the requested case. The complete executable handoffs are documented in [matching-api.md](../../docs/matching-api.md) and [packet-api.md](../../docs/packet-api.md).

The administrative answer model is `lib/shared/models/form_answers.dart`; the read/save/reload client is `lib/shared/services/form_answers_api_client.dart`. Its tests separately check JSON Schema conditional/array constraints and runtime cross-field invariants. Form save requests replace all answers; omitted keys clear them. `FORM_SAVE_UNCERTAIN` is a local client error, not a server code: reload the case, then its answers before deciding on another save. Run `dart run tool/check_form_answers_api.dart --backend ../safe-at-home-backend/backend` for the fictional real-HTTP round trip, concurrency, clearing and lost-response recovery check. The backend branch's `docs/form-answers-api.md` describes the adapter and UI handoff; combine that branch before using these endpoints.
