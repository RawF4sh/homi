# Shared contracts v1

These files define the first Flutter/backend handoff. The schemas use JSON Schema 2020-12. Configure a full validator to assert `format` checks when adopting one; the dependency-free Dart tests cover the subset currently used here.

- `case.schema.json`: case/profile, reviewed findings, and measurements. Required nullable fields use explicit `null` for unknown. Zero and false are known values. `ownerConsentReported` records an answer, not verified permission. Evidence IDs refer to private evidence records; the fixture does not contain real photos.
- `match.schema.json`: explained results returned by the future backend. The Dart models validate structure and source references; they do not evaluate eligibility. `evaluationDate` is an explicit input to the server's policy evaluation, while `evaluatedAt` records when it ran. `recheckAfter: null` means the cache cannot establish freshness. Rule updates can invalidate a result earlier than its deadline.
- `packet.schema.json`: a proposed draft-only response for later packet work. Unknown form/mapping/storage fields remain null until verified or generated. A draft is never proof of submission or approval.
- `fixtures/scenarios.json`: three prewritten, entirely fictional scenarios. The example route checks only `Demo City` and `Example Plan`. These values are teaching data with no real program sources, intake, or benefit policy. No live matcher, backend, or PDF generator is included in the fixtures.

The Dart boundary in `lib/shared/models/contracts.dart` rejects unsupported schema versions, missing/extra fields, invalid types, dates and enums, and inconsistent references. Lists are immutable after parsing. The asset adapter in `lib/shared/services/demo_scenario_service.dart` reads the shared JSON for the first UI demo.

Fixture dates are deliberately fixed for repeatability. At or after their recheck deadline they are stale; tests provide explicit times, and a UI showing them should retain the demo label rather than calling them current program advice.

Run `flutter test test/contracts` from the application root. These tests check the fictional fixture handoff, unknown/zero/false handling, malformed data, source references, and case/date freshness boundaries. They do not validate any real program rule.
