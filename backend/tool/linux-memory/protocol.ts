import { readFile } from 'node:fs/promises';
import type { CaseDraft } from '../../src/cases/types.ts';
import { createPostgresPool } from '../../src/storage/postgres-pool.ts';
import { SCENARIOS, type Scenario } from '../memory/workload.ts';
import type { FixtureName } from '../memory/fixture.ts';

export const DATABASE = 'safememory';
export const ADMIN_PASSWORD = 'sah-synthetic-admin';
export const RUNTIME_PASSWORD = 'sah-synthetic-runtime-password-32bytes';
export const OWNER = 'a0000000-0000-4000-8000-000000000001';
export const OTHER = 'b0000000-0000-4000-8000-000000000002';
export const TOKEN = 'synthetic-linux-memory-owner-token';
export const OTHER_TOKEN = 'synthetic-linux-memory-other-token';
export const CASE_ID = 'c0000000-0000-4000-8000-000000000003';
export const AGGREGATE_CASE_ID = 'd0000000-0000-4000-8000-000000000004';
export const API_ORIGIN = 'http://api:8788';
export const AUTH = { projectUrl: 'https://synthetic-memory.invalid', publishableKey: 'sb_publishable_synthetic_linux_memory' };
export const baseRequest = { schemaVersion: '1' as const, caseId: CASE_ID, expectedCaseRevision: 1 };

export function syntheticDiagnostic(phase: string, error: unknown) {
  const name = error instanceof Error && /^[A-Za-z][A-Za-z0-9]{0,48}$/.test(error.name) ? error.name : 'Error';
  const permittedCodes = new Set(['ECONNREFUSED', 'ECONNRESET', 'ENOTFOUND', 'ETIMEDOUT', 'EACCES', 'ENOENT', 'EADDRINUSE',
    'ERR_TLS_CERT_ALTNAME_INVALID', 'SELF_SIGNED_CERT_IN_CHAIN', 'DEPTH_ZERO_SELF_SIGNED_CERT', 'CERT_HAS_EXPIRED',
    'UNABLE_TO_VERIFY_LEAF_SIGNATURE', '42501', '28P01', '3D000', '42P01', '08006', '53300', '57014']);
  const code = error && typeof error === 'object' && 'code' in error && typeof error.code === 'string'
    && permittedCodes.has(error.code) ? error.code : undefined;
  console.error(JSON.stringify({ kind: 'synthetic-diagnostic', phase, errorName: name, ...(code ? { code } : {}) }));
}

export function parseScenario(value: string): Scenario {
  if (!SCENARIOS.includes(value as Scenario)) throw new Error('Unknown synthetic scenario.');
  return value as Scenario;
}
export function scenarioFixture(scenario: Scenario): { name: FixtureName; count: number } {
  switch (scenario) {
    case 'pdf-alpha-16mp': return { name: 'alpha.png', count: 1 };
    case 'pdf-six-16mp': return { name: 'six.png', count: 6 };
    case 'pdf-near24mb': case 'pdf-repeat-16mp': return { name: 'near24.png', count: 1 };
    case 'upload-near8mb-jpeg': return { name: 'near8.jpg', count: 1 };
    case 'upload-16mp-jpeg': case 'upload-repeat-16mp': return { name: 'full16mp.jpg', count: 1 };
    case 'reject-oversize': return { name: 'solid.png', count: 2 };
    case 'pdf-solid-16mp': return { name: 'solid.png', count: 1 };
  }
}
export function syntheticDraft(count: number, caseId = CASE_ID): CaseDraft {
  return { schemaVersion: '1', caseId,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
      householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [],
    findings: [{ id: 'synthetic-finding', room: 'entrance', observation: 'Generated pixels for disposable capacity testing only.',
      reviewState: 'confirmed', evidenceIds: Array.from({ length: count }, (_, index) => `synthetic-photo-${index + 1}`), measurements: [] }] };
}

export async function syntheticPool(administrative = false) {
  const user = administrative ? 'postgres' : 'safeathome_runtime';
  const password = administrative ? ADMIN_PASSWORD : RUNTIME_PASSWORD;
  return createPostgresPool({ connectionString: `postgresql://${user}:${password}@postgres:5432/${DATABASE}`,
    caCertificate: await readFile('/lab/ca.crt', 'utf8') });
}

export const syntheticAuthFetch: typeof fetch = async (input, options) => {
  const headers = new Headers(options?.headers);
  if (input !== `${AUTH.projectUrl}/auth/v1/user` || options?.method !== 'GET' || options.redirect !== 'error'
    || headers.get('apikey') !== AUTH.publishableKey) throw new Error('Unexpected synthetic auth request.');
  const bearer = headers.get('authorization');
  if (bearer !== `Bearer ${TOKEN}` && bearer !== `Bearer ${OTHER_TOKEN}`) return Response.json({}, { status: 401 });
  return Response.json({ id: bearer === `Bearer ${TOKEN}` ? OWNER : OTHER, role: 'authenticated',
    user_metadata: { ownerId: 'ignored-synthetic-forged-owner' } });
};
