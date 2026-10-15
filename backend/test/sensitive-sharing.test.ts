import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseSensitiveRequest, sensitiveQuestionMetadata, SENSITIVE_ROUTES, type SensitiveRoute } from '../src/sharing/sensitive.ts';
import { handleSharing } from '../src/api/sharing.ts';
const fixtures = JSON.parse(readFileSync(new URL('../../contracts/v3/fixtures/sensitive-sharing.json', import.meta.url), 'utf8'));
test('all eight selected-data request fixtures parse and reject forged privilege/category/owner fields', () => {
  for (const fixture of fixtures) {
    assert.deepEqual(parseSensitiveRequest(fixture.route, fixture.request), fixture.request);
    for (const key of ['ownerId', 'recipientId', 'allPhotos', 'category', 'pdfUrl', 'serviceRole', 'content']) {
      assert.throws(() => parseSensitiveRequest(fixture.route, { ...fixture.request, [key]: 'forged' }));
    }
  }
});
test('source categories are exact-version server metadata with independent financial, health and other-private groups', () => {
  const metadata = sensitiveQuestionMetadata()['scfhp-eaa'];
  assert.equal(metadata.questions.find(q => q.key === 'estimatedCostUsd')!.category, 'financial');
  assert.equal(metadata.questions.find(q => q.key === 'professionalOrderReported')!.category, 'health');
  assert.equal(metadata.questions.find(q => q.key === 'willingServicesReported')!.category, 'private');
  assert.equal(Object.hasOwn(sensitiveQuestionMetadata(), 'invented-program'), false);
});
test('selected-data endpoints stay denied until their separate trusted feature flag is enabled', async () => {
  let executed = false;
  const deps = { authenticate: async () => ({ userId: 'fictional-owner' }), sharing: {
    execute: async () => ({ status: 'ok' as const, data: {} }),
    sensitive: async () => { executed = true; return { status: 'not_found' as const }; },
  } };
  for (const route of SENSITIVE_ROUTES) {
    const request = fixtures.find((f: any) => f.route === route).request;
    assert.equal((await handleSharing({ body: request, bearerToken: 'fictional-token' }, deps, route)).status, 404);
  }
  assert.equal(executed, false);
  await handleSharing({ body: fixtures[0].request, bearerToken: 'fictional-token' }, { ...deps, sensitiveEnabled: true }, fixtures[0].route as SensitiveRoute);
  assert.equal(executed, true);
});
