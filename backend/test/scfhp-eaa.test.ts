import assert from 'node:assert/strict';
import test from 'node:test';
import { matchPrograms } from '../src/matcher.ts';
import { planDraftPacket } from '../src/packets.ts';
import { createScfhpEaaResearchProgram } from '../src/programs/scfhp-eaa.ts';
import type { CaseSnapshot } from '../src/types.ts';

const context = { evaluatedAt: '2026-10-17T19:00:00Z', evaluationDate: '2026-10-17' };
function fictionalCase(): CaseSnapshot {
  return {
    schemaVersion: '1', caseId: 'fictional-scfhp-research', revision: 1,
    profile: { city: 'San Jose', county: 'Santa Clara', healthPlan: 'SCFHP', tenure: 'renter',
      ageYears: 70, householdSize: 1, annualIncomeUsd: null, ownerConsentReported: null },
    unresolvedFields: [], findings: [],
  };
}

test('real-source research route never declares policy verified, capacity open or freshness known', () => {
  const program = createScfhpEaaResearchProgram();
  assert.equal(program.isDemo, false);
  assert.equal(program.rulesVerified, false);
  assert.equal(program.availability, 'unverified');
  assert.equal(program.recheckAfter, null);
  assert.equal(program.effectiveFrom, null);
  assert.equal(program.effectiveUntil, null);
  assert.equal(program.criteria.length, 7);
  assert.ok(program.criteria.every(criterion => criterion.rule.kind === 'manual_review' && criterion.rule.sourceIds.length > 0));
  assert.match(program.programName, /research preview/);
});

test('profile, tenure, income, age and observations cannot substitute for reviewed SCFHP decisions', () => {
  const edits: Array<(snapshot: CaseSnapshot) => void> = [
    () => {},
    snapshot => { snapshot.profile.healthPlan = null; },
    snapshot => { snapshot.profile.healthPlan = 'Another plan'; },
    snapshot => { snapshot.profile.city = 'Another city'; snapshot.profile.county = 'Another county'; },
    snapshot => { snapshot.profile.tenure = 'owner'; },
    snapshot => { snapshot.profile.tenure = null; },
    snapshot => { snapshot.profile.ownerConsentReported = true; },
    snapshot => { snapshot.profile.ownerConsentReported = false; },
    snapshot => { snapshot.profile.ageYears = 0; },
    snapshot => { snapshot.profile.annualIncomeUsd = 0; },
    snapshot => { snapshot.profile.annualIncomeUsd = 1_000_000; },
    snapshot => { snapshot.unresolvedFields = ['profile.healthPlan']; },
    snapshot => { snapshot.findings = [{ id: 'observed-step', room: 'entrance', observation: 'A step was observed.',
      reviewState: 'confirmed', evidenceIds: ['unattached-photo'], measurements: [] }]; },
  ];
  for (const edit of edits) {
    const snapshot = fictionalCase(); edit(snapshot);
    const result = matchPrograms(snapshot, [createScfhpEaaResearchProgram()], context).matches[0];
    assert.equal(result.status, 'needs_confirmation');
    assert.ok(result.checks.every(check => check.status === 'unknown' && check.reasonCode === 'rules_unverified'));
    assert.equal(result.recheckAfter, null);
    assert.ok(result.checks.every(check => check.sourceIds.length > 0));
  }
});

test('research packet keeps form, evidence, consent and program review unresolved', () => {
  const snapshot = fictionalCase();
  snapshot.profile.ownerConsentReported = true;
  const match = matchPrograms(snapshot, [createScfhpEaaResearchProgram()], context).matches[0];
  const packet = planDraftPacket(snapshot, match, { packetId: 'research-draft', generatedAt: context.evaluatedAt });
  assert.equal(packet.status, 'draft');
  assert.equal(packet.formVersion, null);
  assert.equal(packet.storageReference, null);
  assert.deepEqual(packet.attachments, []);
  assert.ok(packet.missingItems.some(item => item.id === 'check:property-permission'));
  assert.ok(packet.missingItems.some(item => item.id === 'check:consent'));
  assert.ok(packet.missingItems.some(item => item.id === 'check:cost-and-prior-use'));
});

test('research registry returns isolated records and its source links remain explicit', () => {
  const first = createScfhpEaaResearchProgram();
  const second = createScfhpEaaResearchProgram();
  assert.deepEqual(first, second);
  first.sources[0].title = 'Changed'; first.criteria.length = 0;
  assert.notEqual(createScfhpEaaResearchProgram().sources[0].title, 'Changed');
  assert.equal(second.criteria.length, 7);
  const sourceIds = new Set(second.sources.map(source => source.id));
  for (const criterion of second.criteria) {
    assert.equal(criterion.rule.kind, 'manual_review');
    if (criterion.rule.kind === 'manual_review') {
      assert.ok(criterion.rule.sourceIds.every(id => sourceIds.has(id)));
    }
  }
});
