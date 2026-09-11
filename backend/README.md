# Standalone matcher

The matcher is a hosting-independent TypeScript module with no runtime dependencies or I/O. It now has a separate authenticated API core and local HTTP demo; no production database or cloud deployment is configured. The only included program is fictional. No real eligibility thresholds or current program rules are implemented.

Run from this `backend/` directory with a Node version supporting native TypeScript stripping (tested on Node 25.2.1):

```bash
npm test
```

Before the shared baseline is integrated into this worktree, explicitly read its canonical fixtures from the original checkout:

```bash
npm run demo -- ../../safe-at-home/contracts/v1/fixtures/scenarios.json
npm run test:contracts -- ../../safe-at-home/contracts/v1/fixtures/scenarios.json
```

After a human integrates the baseline, the default paths work:

```bash
npm run demo
npm run test:contracts
```

The shared scenarios remain in `contracts/v1/fixtures/scenarios.json`; this branch does not copy or maintain a second version. Unit tests construct their own minimal synthetic inputs. The contract check compares identity, revisions, timestamps, statuses, missing fields, sources, and program metadata while allowing explanatory wording and reason codes to differ.

## Interface and interpretation

`matchPrograms(snapshot, registry, context)` validates unknown inputs and returns the v1 response. Invalid shapes, unsupported keys, wrong types, impossible dates, and malformed rules throw `InputValidationError`. Profile strings must be nonblank or null; false and numeric zero are preserved. Income may be any finite number, including a negative value, as defined in the shared contract.

Supply both `evaluatedAt` (UTC ISO timestamp ending in Z, with zero or one to six fractional digits) and its matching `evaluationDate`. Deadline comparisons preserve microsecond precision. The function never reads the current clock. Callers must use current, trusted server time for a live evaluation; the demo intentionally uses a fixed timestamp.

Rules support equality, inclusive numeric lower/upper bounds, AND/OR groups, and explicit criterion exceptions. Missing or conflicting answers produce unknown checks. An unresolved applicable exception prevents rejecting that criterion. An independent verified failure may still fail the overall program while unrelated unknown checks remain visible.

Real program records need verified rules, a review date, referenced sources on every leaf, and a recheck deadline. The engine verifies metadata consistency, not the truth or official ownership of a webpage. Human source review is still necessary. Current-source failures make the program checks unknown; availability remains separate from the eligibility result.

`recheckAfter` is capped at the earliest supplied review deadline or program/source effective transition. Effective-until dates include that whole UTC day; expiry is the following midnight. Null means no reusable freshness guarantee. Consumers must also invalidate responses after case revision or rule version changes. A possible match is never program approval.

Native Node strips type syntax but does not type-check. TypeScript 5.9.3 and Node24 declarations are now pinned development dependencies, with a lockfile for reproducible installs. Run:

```bash
npm ci --ignore-scripts
npm run typecheck
npm test
```

This type-checks source and tests without emission or skipped library checking. Dependencies under `node_modules` are ignored; runtime and Node tests remain dependency-free.

## Local authenticated API

`src/api/match-case.ts` implements `handleMatchCase` using injected authentication, case repository and registry adapters. It authenticates first, loads an owner-scoped case, checks the expected revision, evaluates server-selected rules/time and returns success only after an atomic ownership/revision check and save. Missing/inaccessible cases share the same 404. The local memory adapter is not durable storage.

Run the demo before the shared baseline is integrated:

```bash
npm run serve:demo -- --fixtures ../../safe-at-home/contracts/v1/fixtures/scenarios.json
```

After integration, omit `--fixtures` and its value. The server binds only to `127.0.0.1:8787`, creates random temporary sessions for Alice and Bob, and prints their tokens and fictional case IDs. `--port 0` selects an available local port. `--machine` emits a JSON readiness line for the integration script; it contains temporary demo tokens and should not be copied to shared logs. Stop with Ctrl+C; sessions, cases and saved matches disappear.

`POST /v1/match-case` requires `Authorization: Bearer TOKEN`, JSON content type, and exactly:

```json
{"schemaVersion":"1","caseId":"demo-case-matched","expectedCaseRevision":1}
```

Client identity, profile values, rule versions and clock overrides are rejected. Requests are limited to 16 KiB actual bytes. Every application response has `Cache-Control: no-store`; malformed requests, inaccessible cases and revision conflicts produce safe error envelopes. Dependencies must enforce their own bounded operational deadlines when production adapters are added.

The fixture registry has a fixed historical deadline for repeatable tests. Only the local server creates a one-hour fictional demo-session deadline on startup, so it remains usable on later dates. This never changes real policy metadata or the original fixtures. API 200 means evaluated/saved; clients must still check case identity/revision, rule updates and `recheckAfter` before treating a response as current.

From the separate Flutter checkout, exercise the actual Dart transport and this server together:

```bash
dart run tool/check_matching_api.dart --backend ../safe-at-home-backend/backend
```

After both branches are combined, omit the `--backend` argument. The script starts and stops its own local server and checks all three outcomes, valid/invalid sessions, user isolation, revision conflicts and late client responses. The fuller UI/production handoff is `docs/matching-api.md` in the baseline branch.

Production still needs a confirmed hosting choice, a real identity provider, durable authorized storage with transactional compare-and-save, and verified program records. Do not deploy the demo token service or memory store. No photo/packet storage or submission integration is included.
