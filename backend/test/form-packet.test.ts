import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { demoContext, demoProgram } from '../fixtures/demo-program.ts';
import { handlePreparePacket, type PreparePacketDependencies, type PreparePacketResult } from '../src/api/prepare-packet.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { defineVerifiedFormTemplate, type VerifiedFormTemplate } from '../src/forms/field-mapping.ts';
import type { CaseSnapshot, DraftPacket } from '../src/types.ts';

function fixture() {
  const bytes = Buffer.from('%PDF-1.7\nSynthetic API form pin\n%%EOF\n');
  const sha = createHash('sha256').update(bytes).digest('hex');
  const template = defineVerifiedFormTemplate({ schemaVersion: '1', programId: demoProgram.programId,
    templateSha256: sha, formVersion: `sha256:${sha}`, mappingVersion: 'synthetic-v1',
    publisherRevision: null, sourceUrl: 'https://example.org/form.pdf', sourcePageUrl: 'https://example.org/forms',
    reviewedOn: '2026-10-12', pageCount: 1,
    fields: [
      { fieldName: 'service', label: 'Selected synthetic route', pdfType: 'Btn', semantic: 'routing', required: false, maxLength: null,
        widgets: [{ page: 1, rect: [10, 10, 20, 20], exportValue: 'Other' }, { page: 1, rect: [10, 30, 20, 40], exportValue: 'On' }],
        binding: { kind: 'routing', programId: demoProgram.programId, widgetIndex: 1, value: 'On' } },
      { fieldName: 'name', label: 'Resident identity', pdfType: 'Tx', semantic: 'identity', required: false, maxLength: null,
        widgets: [{ page: 1, rect: [30, 10, 100, 20], exportValue: null }],
        binding: { kind: 'manual', reason: 'not_collected', resolvedBy: 'resident' } },
      { fieldName: 'consent', label: 'Actual consent', pdfType: 'Btn', semantic: 'consent', required: false, maxLength: null,
        widgets: [{ page: 1, rect: [30, 30, 40, 40], exportValue: 'Yes' }],
        binding: { kind: 'manual', reason: 'consent_review', resolvedBy: 'resident' } },
      { fieldName: 'heading', label: 'Layout heading', pdfType: 'Tx', semantic: 'layout', required: false, maxLength: null,
        widgets: [{ page: 1, rect: [30, 50, 100, 60], exportValue: null }],
        binding: { kind: 'manual', reason: 'layout_only', resolvedBy: 'program' } },
    ],
  });
  return { bytes, template };
}

const request = { schemaVersion: '1', caseId: 'fictional-form-alice', expectedCaseRevision: 1,
  programId: demoProgram.programId, generationKey: 'form-attempt-001' };

function setup() {
  const snapshot: CaseSnapshot = { schemaVersion: '1', caseId: request.caseId, revision: 1,
    profile: { city: 'Demo City', county: null, healthPlan: 'Example Plan', tenure: 'owner', ageYears: 70,
      householdSize: null, annualIncomeUsd: null, ownerConsentReported: true }, unresolvedFields: [], findings: [] };
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot }]);
  const form = fixture(); let now = demoContext.evaluatedAt; let sequence = 0; let loads = 0;
  const deps: PreparePacketDependencies = {
    authenticate: async token => token === 'alice' || token === 'bob' ? { userId: token } : null,
    cases, loadRegistry: async () => [structuredClone(demoProgram)],
    loadFormTemplate: async () => { loads++; return form; },
    now: () => new Date(now), newPacketId: () => `synthetic-form-${++sequence}`, allowDemoPrograms: true,
  };
  return { deps, form, cases, loads: () => loads, setNow: (value: string) => { now = value; },
    send: (body: unknown = request, bearerToken: string | null = 'alice') => handlePreparePacket({ body, bearerToken }, deps) };
}

function success(result: PreparePacketResult): DraftPacket {
  assert.equal(result.status, 200); assert.ok('packetId' in result.body); return result.body;
}
function failure(result: PreparePacketResult, status: number, code: string) {
  assert.equal(result.status, status); assert.ok('error' in result.body); assert.equal(result.body.error.code, code);
  assert.equal(result.headers?.['Cache-Control'], 'no-store');
}

test('optional verified form yields versioned review tasks in the unchanged draft-only v1 response', async () => {
  const state = setup(); const packet = success(await state.send());
  assert.equal(packet.formVersion, state.form.template.formVersion);
  assert.equal(packet.mappingVersion, 'synthetic-v1'); assert.equal(packet.status, 'draft');
  assert.equal(packet.storageReference, null); assert.deepEqual(packet.attachments, []);
  assert.ok(packet.missingItems.some(item => item.id === 'form-currentness'));
  assert.ok(packet.missingItems.some(item => item.id === 'form-rendering'));
  assert.deepEqual(packet.missingItems.filter(item => item.id.startsWith('form-field:')).map(item => item.id), ['form-field:1', 'form-field:2']);
  assert.ok(!packet.missingItems.some(item => item.id === 'official-form' || item.id === 'field-mapping'));
  assert.equal(Object.hasOwn(packet, 'fields'), false);
});

test('unchanged form retry returns exact saved packet despite later evaluation time', async () => {
  const state = setup(); const first = success(await state.send());
  state.setNow('2026-10-13T19:01:00Z');
  assert.deepEqual(success(await state.send()), first); assert.equal(state.loads(), 2);
});

test('full mapping metadata and byte pin invalidate a retry even if mappingVersion is not bumped', async () => {
  const changes: Array<(template: Record<string, any>, bytes: Buffer) => Buffer> = [
    (template, bytes) => { template.mappingVersion = 'synthetic-v2'; return bytes; },
    (template, bytes) => { template.fields[1].label = 'Reviewed identity label'; return bytes; },
    (template, bytes) => { template.fields[0].widgets[1].rect[0] = 11; return bytes; },
    (template, bytes) => { template.sourceUrl = 'https://example.org/new-form.pdf'; return bytes; },
    (template, bytes) => { template.publisherRevision = 'Reviewed publisher revision'; return bytes; },
    (template, bytes) => { const next = Buffer.concat([bytes, Buffer.from('\nchanged')]);
      template.templateSha256 = createHash('sha256').update(next).digest('hex'); template.formVersion = `sha256:${template.templateSha256}`; return next; },
  ];
  for (const change of changes) {
    const state = setup(); success(await state.send());
    const template = structuredClone(state.form.template) as unknown as Record<string, any>;
    const bytes = change(template, Buffer.from(state.form.bytes));
    state.deps.loadFormTemplate = async () => ({ template: defineVerifiedFormTemplate(template), bytes });
    failure(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
    success(await state.send({ ...request, generationKey: 'new-form-attempt' }));
  }
});

test('adding or removing a form adapter invalidates old preparation intent', async () => {
  for (const direction of ['add', 'remove']) {
    const state = setup(); const loader = state.deps.loadFormTemplate;
    if (direction === 'add') state.deps.loadFormTemplate = undefined;
    success(await state.send());
    state.deps.loadFormTemplate = direction === 'add' ? loader : undefined;
    failure(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
  }
});

test('null template preserves generic draft behavior without invented form versions', async () => {
  const state = setup(); state.deps.loadFormTemplate = async () => null;
  const packet = success(await state.send()); assert.equal(packet.formVersion, null); assert.equal(packet.mappingVersion, null);
  assert.ok(packet.missingItems.some(item => item.id === 'official-form'));
});

test('form loading follows authentication, access, revision, program validation and demo opt-in', async () => {
  for (const scenario of ['auth', 'access', 'revision', 'program', 'demo']) {
    const state = setup();
    if (scenario === 'auth') failure(await state.send(request, null), 401, 'UNAUTHENTICATED');
    if (scenario === 'access') failure(await state.send(request, 'bob'), 404, 'CASE_NOT_FOUND');
    if (scenario === 'revision') failure(await state.send({ ...request, expectedCaseRevision: 2 }), 409, 'CASE_REVISION_MISMATCH');
    if (scenario === 'program') failure(await state.send({ ...request, programId: 'unknown' }), 404, 'PROGRAM_NOT_FOUND');
    if (scenario === 'demo') { state.deps.allowDemoPrograms = false; failure(await state.send(), 500, 'INTERNAL_ERROR'); }
    assert.equal(state.loads(), 0);
  }
});

test('client form definitions, values, URLs and versions cannot override the server', async () => {
  for (const key of ['formVersion', 'mappingVersion', 'templateSha256', 'template', 'formValues', 'formUrl']) {
    const state = setup(); failure(await state.send({ ...request, [key]: 'untrusted' }), 400, 'INVALID_REQUEST');
    assert.equal(state.loads(), 0);
  }
});

test('loader errors, changed bytes and malformed internal templates fail without generic fallback', async () => {
  const loaders: Array<PreparePacketDependencies['loadFormTemplate']> = [
    async () => { throw new Error('PRIVATE_USER_TOKEN'); },
    async () => ({ ...fixture(), bytes: Buffer.from('%PDF-1.7 changed') }),
    async () => ({ ...fixture(), template: {} as VerifiedFormTemplate }),
    async () => ({ ...fixture(), template: { ...fixture().template, programId: 'other' } }),
    async () => undefined as never,
  ];
  for (const [index, loader] of loaders.entries()) {
    const state = setup(); state.deps.loadFormTemplate = loader;
    const result = await state.send(); failure(result, index === 0 ? 503 : 500, index === 0 ? 'SERVICE_UNAVAILABLE' : 'INTERNAL_ERROR');
    assert.doesNotMatch(JSON.stringify(result), /PRIVATE_USER_TOKEN|example.org/);
  }
});

test('source expiry during form loading cannot produce a current draft', async () => {
  const state = setup(); state.deps.loadFormTemplate = async () => { state.setNow(demoProgram.recheckAfter!); return state.form; };
  failure(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
});

test('case revision and ownership must still be checked atomically after form loading', async () => {
  for (const status of ['conflict', 'not_found'] as const) {
    const state = setup(); let loaded = false;
    state.deps.loadFormTemplate = async () => { loaded = true; return state.form; };
    state.deps.cases = { loadForUser: (userId, caseId) => state.cases.loadForUser(userId, caseId),
      createPacketIfCurrent: async () => { assert.equal(loaded, true); return { status }; } };
    failure(await state.send(), status === 'conflict' ? 409 : 404, status === 'conflict' ? 'CASE_REVISION_MISMATCH' : 'CASE_NOT_FOUND');
  }
});

test('mutating adapter objects during persistence cannot alter the detached preparation', async () => {
  const state = setup(); const raw = structuredClone(state.form.template);
  state.deps.loadFormTemplate = async () => ({ template: raw, bytes: state.form.bytes });
  state.deps.cases = { loadForUser: (userId, caseId) => state.cases.loadForUser(userId, caseId),
    createPacketIfCurrent: async input => {
      (raw as unknown as { mappingVersion: string }).mappingVersion = 'changed-during-save';
      state.form.bytes.fill(0);
      return state.cases.createPacketIfCurrent(input);
    } };
  assert.equal(success(await state.send()).mappingVersion, 'synthetic-v1');
});

test('repository cannot substitute another form version or invented rendered file', async () => {
  for (const override of [{ formVersion: 'other' }, { storageReference: 'private/fake.pdf' }]) {
    const state = setup();
    state.deps.cases = { loadForUser: (userId, caseId) => state.cases.loadForUser(userId, caseId),
      createPacketIfCurrent: async input => ({ status: 'saved', packet: { ...input.packet, ...override } }) };
    failure(await state.send(), 500, 'INTERNAL_ERROR');
  }
});
