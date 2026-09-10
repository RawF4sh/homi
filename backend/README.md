# Standalone matcher

This is a hosting-independent TypeScript module, with no runtime dependencies, network calls, database, or deployment configuration. The only included program is fictional. No real eligibility thresholds or current program rules are implemented.

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

No compiler dependency is installed. Native Node strips type syntax but does not type-check. During implementation, strict no-emit checking used an already-installed TypeScript 5.9.3 compiler; library declaration checking was skipped because that unrelated installation bundles older Node declarations.
