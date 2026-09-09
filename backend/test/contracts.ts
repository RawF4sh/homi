import assert from 'node:assert/strict';
import { matchPrograms } from '../src/matcher.ts';
import { readSharedScenarios } from '../src/shared-fixtures.ts';
import type { MatchResponse } from '../src/types.ts';
import { demoProgram } from '../fixtures/demo-program.ts';

function semanticResponse(response: MatchResponse) {
  return {
    ...response,
    matches: response.matches.map(match => ({
      ...match,
      checks: match.checks.map(({ reasonCode, explanation, ...check }) => {
        assert.ok(reasonCode.trim(), 'Every check needs a reason code.');
        assert.ok(explanation.trim(), 'Every check needs an explanation.');
        return check;
      }),
    })),
  };
}

const scenarios = readSharedScenarios(process.argv[2]);
for (const scenario of scenarios) {
  const response = matchPrograms(scenario.case, [demoProgram], {
    evaluatedAt: scenario.match.evaluatedAt, evaluationDate: scenario.match.evaluationDate,
  });
  assert.deepEqual(semanticResponse(response), semanticResponse(scenario.match), `Shared scenario ${scenario.id} disagrees with the matcher.`);
  console.log(`Verified shared scenario: ${scenario.id}`);
}
console.log(`All ${scenarios.length} shared contract scenarios agree.`);
