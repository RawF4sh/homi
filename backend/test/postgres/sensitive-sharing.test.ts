import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { before, after, test } from 'node:test';
import type { Pool } from 'pg';
import { PDFDocument } from 'pdf-lib';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { captureDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
import { seedSensitive, OWNER, HELPER, VIEWER, OTHER } from '../support/sensitive-fixture.ts';
import { parseSensitiveRequest, sensitiveId, type SensitiveRoute, type SensitiveRequest } from '../../src/sharing/sensitive.ts';
import { handleSharing } from '../../src/api/sharing.ts';
let cluster: TestPostgres, admin: Pool, runtime: Pool;
before(async () => { cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE sensitive_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app'); runtime = cluster.pool('sensitive_runtime'); });
after(async () => { await cluster?.close(); });
const base = (s: Awaited<ReturnType<typeof seedSensitive>>, revision = 2) => ({ schemaVersion: '3' as const, membershipId: s.membershipId, expectedPermissionRevision: revision });
const ok = (r: any): any => { assert.equal(r.status, 'ok', JSON.stringify(r)); return r.data; };
async function preview(s: Awaited<ReturnType<typeof seedSensitive>>, pdf = false) {
  const options = ok(await s.shares.sensitive(OWNER, 'list-sensitive-options', base(s)));
  const fields = { ...base(s), expectedCaseRevision: options.caseRevision, expectedCatalogRevision: options.catalogRevision,
    selection: { photoIds: options.content.photos.map((p: any) => p.evidenceId), measurementIds: options.content.measurements.map((m: any) => m.id),
      answerIds: options.content.answers.filter((a: any) => a.category !== 'private').map((a: any) => a.id) },
    allowPdf: pdf, expiresAt: new Date(Date.now() + 86400000).toISOString() };
  return { fields, data: ok(await s.shares.sensitive(OWNER, 'preview-sensitive-sharing', fields)) };
}
async function publish(s: Awaited<ReturnType<typeof seedSensitive>>, pdf = false) {
  const p = await preview(s, pdf), request = { ...p.fields, mutationId: randomUUID(), previewHash: p.data.sourceHash };
  return { ...p, request, saved: ok(await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', request)) };
}
test('explicit selection preserves false/zero/unknown, independent PDF opt-in and exact photo bytes; private owner records remain RLS protected', async () => {
  const s = await seedSensitive(runtime);
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s))).status, 'not_found');
  const p = await publish(s);
  assert.equal(p.saved.permissionRevision, 3);
  assert.equal(p.data.content.measurements[0].id, sensitiveId('measurement', 'fictional-finding', 'clear_width'));
  const read = ok(await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 3)));
  assert.deepEqual(read.content.answers.map((a: any) => a.value).sort(), [0, false, null].sort());
  assert.ok(!JSON.stringify(read).includes('willingServicesReported'));
  const photo = ok(await s.shares.sensitive(HELPER, 'read-sensitive-photo', { ...base(s, 3), sourceHash: read.sourceHash,
    evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 }));
  assert.deepEqual(Buffer.from(photo.photoBase64, 'base64'), Buffer.from(s.photo.image.bytes));
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-report', { ...base(s, 3), sourceHash: read.sourceHash })).status, 'not_found');
  const client = await runtime.connect();
  try { await client.query('BEGIN'); await client.query("SELECT set_config('safeathome.user_id',$1,true)", [HELPER]);
    for (const table of ['cases', 'evidence', 'program_intake', 'share_sensitive']) assert.equal((await client.query(`SELECT 1 FROM safeathome_private.${table}`)).rowCount, 0);
  } finally { await client.query('ROLLBACK'); client.release(); }
});
test('viewer/unrelated/helper cannot configure, forwarded IDs fail, malformed scopes fail before mutation and exact save retry increments once', async () => {
  const s = await seedSensitive(runtime), viewer = await seedSensitive(runtime, VIEWER, 'viewer'), p = await preview(s);
  for (const actor of [HELPER, VIEWER, OTHER]) assert.equal((await s.shares.sensitive(actor, 'list-sensitive-options', base(s))).status, 'not_found');
  assert.equal((await viewer.shares.sensitive(OWNER, 'list-sensitive-options', base(viewer))).status, 'not_found');
  const request = { ...p.fields, mutationId: randomUUID(), previewHash: p.data.sourceHash };
  assert.equal((await s.shares.sensitive(HELPER, 'publish-sensitive-sharing', request)).status, 'not_found');
  assert.equal((await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', { ...request, previewHash: 'a'.repeat(64) })).status, 'conflict');
  const first = ok(await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', request));
  assert.deepEqual(ok(await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', request)), first);
  assert.equal((await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', { ...request, allowPdf: true })).status, 'conflict');
  assert.throws(() => parseSensitiveRequest('preview-sensitive-sharing', { ...p.fields, selection: { ...p.fields.selection, allPhotos: true } }));
  assert.throws(() => parseSensitiveRequest('preview-sensitive-sharing', { ...p.fields, selection: { ...p.fields.selection, photoIds: ['same', 'same'] } }));
  assert.equal((await s.shares.sensitive(OTHER, 'read-sensitive-sharing', base(s, 3))).status, 'not_found');
});
test('replacement and revocation deny bytes; expiry and changed source bindings never substitute new content', async () => {
  const s = await seedSensitive(runtime), p = await publish(s);
  await s.cases.saveEvidenceIfCurrent({ ...s.photo, revision: 2, expectedCatalogRevision: 1, expectedEvidenceRevision: 1 });
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 3))).status, 'conflict');
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-photo', { ...base(s, 3), sourceHash: p.saved.sourceHash, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'conflict');
  await s.shares.execute(OWNER, 'revoke-sharing', { schemaVersion: '3', caseId: s.caseId, invitationId: s.membershipId, expectedPermissionRevision: 3 });
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.share_sensitive WHERE membership_id=$1', [s.membershipId])).rowCount, 0);
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 3))).status, 'not_found');
});
test('filtered report is generated from selected fields only and rechecks current authentication and authorization after rendering', async () => {
  const s = await seedSensitive(runtime), p = await publish(s, true);
  const deps = { sharing: s.shares, sensitiveEnabled: true, authenticate: async () => ({ userId: HELPER }) };
  const body = { ...base(s, 3), sourceHash: p.saved.sourceHash };
  const result = await handleSharing({ body, bearerToken: 'fictional-helper' }, deps, 'read-sensitive-report');
  assert.equal(result.status, 200);
  const pdf = (result.body as any).report;
  assert.equal((await PDFDocument.load(Buffer.from(pdf.pdfBase64, 'base64'))).getPageCount(), pdf.pageCount);
  const expired = await handleSharing({ body, bearerToken: 'fictional-helper' }, { ...deps, reauthenticate: async () => null }, 'read-sensitive-report');
  assert.equal(expired.status, 401); assert.ok(!JSON.stringify(expired.body).includes('pdfBase64'));
  const revoked = await handleSharing({ body, bearerToken: 'fictional-helper' }, { ...deps, reauthenticate: async () => {
    await s.shares.execute(OWNER, 'revoke-sharing', { schemaVersion: '3', caseId: s.caseId, invitationId: s.membershipId, expectedPermissionRevision: 3 });
    return { userId: HELPER };
  } }, 'read-sensitive-report');
  assert.equal(revoked.status, 409); assert.ok(!JSON.stringify(revoked.body).includes('pdfBase64'));
});
test('backup is validated, quarantine wipes sensitive capabilities and case deletion cascades selected records', async () => {
  const s = await seedSensitive(runtime); await publish(s, true);
  const origin = 'https://fictional-sensitive.supabase.co', archive = await captureDatabaseBackup(admin, origin);
  const target = await TestPostgres.start();
  try { const db = target.pool(); await applyMigrations(db); await restoreDatabaseBackup(db, archive, origin);
    assert.equal((await db.query('SELECT 1 FROM safeathome_private.share_sensitive')).rowCount, 0);
  } finally { await target.close(); }
  assert.equal((await s.cases.deleteCaseIfCurrent({ userId: OWNER, caseId: s.caseId, revision: 2, expectedCatalogRevision: 1 })).status, 'deleted');
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.share_sensitive WHERE membership_id=$1', [s.membershipId])).rowCount, 0);
});
