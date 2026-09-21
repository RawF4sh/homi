import { createHash } from 'node:crypto';
import type { Pool, PoolClient, QueryResultRow } from 'pg';
import type { CaseSnapshot, DraftPacket, MatchResponse } from '../types.ts';
import type { MatchCaseRepository } from '../api/match-case.ts';
import type { CreatePacketInput, CreatePacketResult, PacketCaseRepository } from '../api/prepare-packet.ts';
import type { FormAnswerCaseRepository, FormAnswerReadInput, FormAnswerReadResult,
  FormAnswerSaveInput, FormAnswerSaveResult } from '../api/form-answers.ts';
import type { CaseWriteRepository, CaseWriteResult } from '../cases/repository.ts';
import type { CaseDraft } from '../cases/types.ts';
import { parseCaseDraft } from '../cases/validation.ts';
import { parseSavedFormAnswers, type SavedFormAnswerSet } from '../forms/form-answers.ts';
import { instantMicros, isPacketCurrent } from '../packets.ts';
import type { EvidenceAsset, EvidenceDescriptor, EvidenceSelection } from '../evidence/types.ts';
import type { EvidenceCaseBinding, EvidenceReadInput, EvidenceRepository, EvidenceRepositoryFailure,
  EvidenceSaveInput, ExportCurrentReadInput, ExportPublishInput, ExportReadInput,
  ExportSnapshotInput } from '../evidence/repository.ts';
import { canonicalJson, caseFingerprint, evidenceIdentifier, evidenceInstant, evidenceRevision,
  formAnswersFingerprint, parseEvidenceAsset, parseEvidenceDescriptor, parseEvidenceSelections,
  parseSanitizedEvidenceImage } from '../evidence/validation.ts';
import { parseExportArtifactMetadata } from '../exports/validation.ts';
import type { ExportArtifactMetadata } from '../exports/types.ts';

const S = 'safeathome_private';
const LIMITS = { cases: 64, assets: 64, artifacts: 16, bytes: 64 * 1024 * 1024 };
type Row = QueryResultRow;
interface CaseRow { snapshot: CaseSnapshot; catalogRevision: number }
interface Quota { cases: number; assets: number; artifacts: number; bytes: number }
interface Tx { client: PoolClient; quota: Quota | null }
interface ExportBindings {
  userId: string; revision: number; caseFingerprint: string; programId: string;
  catalogRevision: number; answersFingerprint: string | null; contextFingerprint: string;
  selections: EvidenceSelection[];
}
interface ExportRow {
  artifactId: string; bindings: ExportBindings; metadata: ExportArtifactMetadata;
  invalidated: boolean; lastCheckedAt: string; byteLength: number;
}

function check(value: unknown): asserts value { if (!value) throw new Error('Invalid private repository data.'); }
function integer(value: unknown, zero = false): number {
  const parsed = typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) ? Number(value) : value;
  check(evidenceRevision(parsed, zero)); return parsed;
}
function next(value: number): number { return integer(value + 1); }
function linked(snapshot: CaseSnapshot, descriptor: Pick<EvidenceDescriptor, 'evidenceId' | 'findingId'>, confirmed = false): boolean {
  return snapshot.findings.some(finding => finding.id === descriptor.findingId
    && finding.evidenceIds.includes(descriptor.evidenceId) && (!confirmed || finding.reviewState === 'confirmed'));
}
function savedCase(value: unknown, caseId: string, revision: unknown): CaseSnapshot {
  check(value !== null && typeof value === 'object' && !Array.isArray(value));
  const { revision: storedRevision, ...draft } = value as Record<string, unknown>;
  const version = integer(revision); check(storedRevision === version);
  const parsed = parseCaseDraft(draft, false, 1); check(parsed.caseId === caseId);
  return { ...parsed, revision: version };
}
function exportCurrent(metadata: ExportArtifactMetadata, at: string): boolean {
  const now = instantMicros(at);
  return instantMicros(metadata.generatedAt) <= now && now < instantMicros(metadata.expiresAt)
    && (metadata.recheckAfter === null || now < instantMicros(metadata.recheckAfter));
}
function validatePdf(bytes: Uint8Array, metadata: ExportArtifactMetadata): void {
  check(bytes instanceof Uint8Array && bytes.byteLength === metadata.byteLength
    && Buffer.from(bytes.subarray(0, 5)).toString('ascii') === '%PDF-'
    && createHash('sha256').update(bytes).digest('hex') === metadata.sha256);
}

export class PostgresCaseRepository implements MatchCaseRepository, PacketCaseRepository,
  FormAnswerCaseRepository, EvidenceRepository, CaseWriteRepository {
  private readonly pool: Pool;
  constructor(pool: Pool) { this.pool = pool; }

  private async transaction<T>(userId: string, write: boolean, operation: (tx: Tx) => Promise<T>): Promise<T> {
    check(evidenceIdentifier(userId));
    const client = await this.pool.connect();
    let broken = false;
    try {
      await client.query(write ? 'BEGIN' : 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      await client.query("SET LOCAL lock_timeout = '5s'");
      await client.query("SET LOCAL statement_timeout = '10s'");
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '10s'");
      await client.query("SELECT set_config('safeathome.user_id', $1, true)", [userId]);
      let quota: Quota | null = null;
      if (write) {
        const row = (await client.query(`SELECT * FROM ${S}.repository_quota WHERE singleton FOR UPDATE`)).rows[0];
        check(row); quota = { cases: integer(row.case_count, true), assets: integer(row.asset_count, true),
          artifacts: integer(row.artifact_count, true), bytes: integer(row.stored_bytes, true) };
      }
      const result = await operation({ client, quota });
      await client.query('COMMIT');
      return result;
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch { broken = true; }
      throw error;
    } finally { client.release(broken); }
  }

  private async caseRow(tx: Tx, userId: string, caseId: string, lock = false): Promise<CaseRow | null> {
    check(evidenceIdentifier(caseId));
    const row = (await tx.client.query(`SELECT snapshot, revision, catalog_revision FROM ${S}.cases
      WHERE case_id = $1 AND owner_id = $2${lock ? ' FOR UPDATE' : ''}`, [caseId, userId])).rows[0];
    return row ? { snapshot: savedCase(row.snapshot, caseId, row.revision), catalogRevision: integer(row.catalog_revision, true) } : null;
  }
  private async bound(tx: Tx, input: EvidenceCaseBinding, lock = false): Promise<CaseRow | EvidenceRepositoryFailure> {
    const entry = await this.caseRow(tx, input.userId, input.caseId, lock);
    if (!entry) return { status: 'not_found' };
    check(evidenceRevision(input.revision) && evidenceRevision(input.expectedCatalogRevision, true));
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    if (entry.catalogRevision !== input.expectedCatalogRevision) return { status: 'evidence_conflict' };
    return entry;
  }
  private async clock(tx: Tx, checkedAt?: string): Promise<string> {
    if (checkedAt !== undefined) check(evidenceInstant(checkedAt));
    const row = (await tx.client.query("SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS now")).rows[0];
    check(evidenceInstant(row.now));
    return checkedAt !== undefined && instantMicros(checkedAt) > instantMicros(row.now) ? checkedAt : row.now;
  }
  private async quotaDelta(tx: Tx, cases = 0, assets = 0, artifacts = 0, bytes = 0): Promise<void> {
    check(tx.quota);
    await tx.client.query(`UPDATE ${S}.repository_quota SET case_count=case_count+$1,
      asset_count=asset_count+$2, artifact_count=artifact_count+$3, stored_bytes=stored_bytes+$4 WHERE singleton`,
    [cases, assets, artifacts, bytes]);
    tx.quota.cases += cases; tx.quota.assets += assets; tx.quota.artifacts += artifacts; tx.quota.bytes += bytes;
  }
  private async exportBytes(tx: Tx, caseId: string): Promise<number> {
    return integer((await tx.client.query(`SELECT COALESCE(SUM(octet_length(bytes)),0)::text AS size
      FROM ${S}.exports WHERE case_id=$1`, [caseId])).rows[0].size, true);
  }
  private async invalidateExports(tx: Tx, caseId: string): Promise<void> {
    const bytes = await this.exportBytes(tx, caseId);
    await tx.client.query(`UPDATE ${S}.exports SET bytes=NULL, invalidated=true WHERE case_id=$1`, [caseId]);
    if (bytes) await this.quotaDelta(tx, 0, 0, 0, -bytes);
  }
  private async invalidateCase(tx: Tx, caseId: string): Promise<void> {
    await tx.client.query(`DELETE FROM ${S}.matches WHERE case_id=$1`, [caseId]);
    await tx.client.query(`UPDATE ${S}.packets SET packet=NULL WHERE case_id=$1`, [caseId]);
    await this.invalidateExports(tx, caseId);
  }
  private async answers(tx: Tx, caseId: string, programId: string): Promise<SavedFormAnswerSet | null> {
    const row = (await tx.client.query(`SELECT record, answer_revision FROM ${S}.form_answers
      WHERE case_id=$1 AND program_id=$2`, [caseId, programId])).rows[0];
    if (!row) return null;
    const saved = parseSavedFormAnswers(row.record);
    check(saved.caseId === caseId && saved.programId === programId && saved.answerRevision === integer(row.answer_revision));
    return saved;
  }

  async loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null> {
    return this.transaction(userId, false, async tx => (await this.caseRow(tx, userId, caseId))?.snapshot ?? null);
  }
  async createForUser(userId: string, draft: CaseDraft): Promise<CaseWriteResult> {
    if (!evidenceIdentifier(userId)) return { status: 'invalid_input' };
    let parsed: CaseDraft;
    try { parsed = parseCaseDraft(draft, true); } catch { return { status: 'invalid_input' }; }
    const snapshot: CaseSnapshot = { ...parsed, revision: 1 };
    return this.transaction(userId, true, async tx => {
      await tx.client.query('SAVEPOINT create_case');
      const result = await tx.client.query(`INSERT INTO ${S}.cases(case_id,owner_id,revision,snapshot)
        VALUES($1,$2,1,$3::jsonb) ON CONFLICT(case_id) DO NOTHING RETURNING case_id`,
      [snapshot.caseId, userId, JSON.stringify(snapshot)]);
      if (result.rowCount === 0) return { status: 'id_unavailable' };
      if (tx.quota!.cases >= LIMITS.cases) {
        await tx.client.query('ROLLBACK TO SAVEPOINT create_case'); return { status: 'quota_exceeded' };
      }
      await this.quotaDelta(tx, 1);
      return { status: 'saved', snapshot: structuredClone(snapshot) };
    });
  }
  async replaceIfCurrent(userId: string, caseId: string, revision: number, draft: CaseDraft): Promise<CaseWriteResult> {
    if (![userId, caseId].every(evidenceIdentifier) || !evidenceRevision(revision)) return { status: 'invalid_input' };
    let parsed: CaseDraft;
    try { parsed = parseCaseDraft(draft, false, next(revision)); } catch { return { status: 'invalid_input' }; }
    if (parsed.caseId !== caseId) return { status: 'invalid_input' };
    return this.transaction(userId, true, async tx => {
      const entry = await this.caseRow(tx, userId, caseId, true);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== revision) return { status: 'conflict' };
      const links = new Map(parsed.findings.flatMap(finding => finding.evidenceIds.map(id => [id, finding.id] as const)));
      const rows = (await tx.client.query(`SELECT evidence_id,finding_id,descriptor IS NOT NULL AS active
        FROM ${S}.evidence WHERE case_id=$1`, [caseId])).rows;
      if (rows.some(row => (row.active && links.get(row.evidence_id) !== row.finding_id)
        || (links.has(row.evidence_id) && links.get(row.evidence_id) !== row.finding_id))) return { status: 'evidence_conflict' };
      const snapshot = { ...parsed, revision: next(revision) };
      await tx.client.query(`UPDATE ${S}.cases SET revision=$2,snapshot=$3::jsonb WHERE case_id=$1`,
        [caseId, snapshot.revision, JSON.stringify(snapshot)]);
      await this.invalidateCase(tx, caseId);
      return { status: 'saved', snapshot: structuredClone(snapshot) };
    });
  }
  async saveMatchIfCurrent(userId: string, caseId: string, revision: number, response: MatchResponse): Promise<'saved' | 'not_found' | 'conflict'> {
    const detached = structuredClone(response);
    return this.transaction(userId, true, async tx => {
      const entry = await this.caseRow(tx, userId, caseId, true);
      if (!entry) return 'not_found';
      if (entry.snapshot.revision !== revision) return 'conflict';
      check(detached.caseId === caseId && detached.caseRevision === revision);
      await tx.client.query(`INSERT INTO ${S}.matches(case_id,response) VALUES($1,$2::jsonb)
        ON CONFLICT(case_id) DO UPDATE SET response=EXCLUDED.response`, [caseId, JSON.stringify(detached)]);
      return 'saved';
    });
  }
  async readSavedMatchForUser(userId: string, caseId: string): Promise<MatchResponse | null> {
    return this.transaction(userId, false, async tx => {
      const entry = await this.caseRow(tx, userId, caseId);
      if (!entry) return null;
      const row = (await tx.client.query(`SELECT response FROM ${S}.matches WHERE case_id=$1`, [caseId])).rows[0];
      if (!row || row.response.caseRevision !== entry.snapshot.revision) return null;
      check(row.response.caseId === caseId); return structuredClone(row.response);
    });
  }
  async loadFormAnswersForUser(userId: string, caseId: string, programId: string): Promise<SavedFormAnswerSet | null> {
    return this.transaction(userId, false, async tx => (await this.caseRow(tx, userId, caseId)) ? this.answers(tx, caseId, programId) : null);
  }
  async readFormAnswersIfCurrent(input: FormAnswerReadInput): Promise<FormAnswerReadResult> {
    const request = structuredClone(input);
    return this.transaction(request.userId, false, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== request.revision) return { status: 'conflict' };
      return { status: 'found', saved: await this.answers(tx, request.caseId, request.programId) };
    });
  }
  async saveFormAnswersIfCurrent(input: FormAnswerSaveInput): Promise<FormAnswerSaveResult> {
    const request = structuredClone(input), saved = parseSavedFormAnswers(request.answers);
    return this.transaction(request.userId, true, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId, true);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== request.revision) return { status: 'conflict' };
      const existing = await this.answers(tx, request.caseId, request.programId);
      if ((existing?.answerRevision ?? 0) !== request.expectedAnswerRevision) return { status: 'answers_conflict' };
      const caseRevision = next(entry.snapshot.revision);
      check(saved.caseId === request.caseId && saved.caseRevision === caseRevision && saved.programId === request.programId
        && saved.answerRevision === next(request.expectedAnswerRevision) && saved.updatedBy === request.userId
        && saved.answers.every(answer => answer.reviewedBy === null || answer.reviewedBy === request.userId)
        && (!existing || instantMicros(saved.updatedAt) >= instantMicros(existing.updatedAt)));
      await tx.client.query(`INSERT INTO ${S}.form_answers(case_id,program_id,answer_revision,record)
        VALUES($1,$2,$3,$4::jsonb) ON CONFLICT(case_id,program_id) DO UPDATE
        SET answer_revision=EXCLUDED.answer_revision,record=EXCLUDED.record`,
      [request.caseId, request.programId, saved.answerRevision, JSON.stringify(saved)]);
      await tx.client.query(`UPDATE ${S}.cases SET revision=$2,snapshot=$3::jsonb WHERE case_id=$1`,
        [request.caseId, caseRevision, JSON.stringify({ ...entry.snapshot, revision: caseRevision })]);
      await this.invalidateCase(tx, request.caseId);
      return { status: 'saved', saved, caseRevision };
    });
  }
  async createPacketIfCurrent(input: CreatePacketInput): Promise<CreatePacketResult> {
    const request = structuredClone(input);
    check(/^[A-Za-z0-9_-]{8,128}$/.test(request.generationKey));
    return this.transaction(request.userId, true, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId, true);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== request.revision) return { status: 'conflict' };
      check(request.packet.caseId === request.caseId && request.packet.caseRevision === request.revision);
      const at = await this.clock(tx, request.checkedAt);
      const existing = (await tx.client.query(`SELECT packet,context_fingerprint FROM ${S}.packets
        WHERE case_id=$1 AND generation_key=$2`, [request.caseId, request.generationKey])).rows[0];
      if (existing) {
        if (existing.packet === null || existing.context_fingerprint !== request.contextFingerprint
          || !isPacketCurrent(existing.packet, at)) return { status: 'generation_conflict' };
        return { status: 'reused', packet: structuredClone(existing.packet) };
      }
      check(instantMicros(request.packet.generatedAt) <= instantMicros(at));
      if (request.packet.recheckAfter !== null && !isPacketCurrent(request.packet, at)) return { status: 'generation_conflict' };
      await tx.client.query(`INSERT INTO ${S}.packets(case_id,generation_key,packet_id,context_fingerprint,packet)
        VALUES($1,$2,$3,$4,$5::jsonb)`, [request.caseId, request.generationKey, request.packet.packetId,
        request.contextFingerprint, JSON.stringify(request.packet)]);
      return { status: 'saved', packet: request.packet };
    });
  }

  private descriptor(row: Row, caseId: string): EvidenceDescriptor {
    const descriptor = parseEvidenceDescriptor(row.descriptor);
    check(descriptor.caseId === caseId && descriptor.evidenceId === row.evidence_id
      && descriptor.findingId === row.finding_id && descriptor.evidenceRevision === integer(row.revision)
      && descriptor.preparedAt === row.prepared_at);
    return descriptor;
  }
  private async selected(tx: Tx, snapshot: CaseSnapshot, selections: EvidenceSelection[], bytes: boolean): Promise<
    { descriptors: EvidenceDescriptor[]; assets: EvidenceAsset[] } | EvidenceRepositoryFailure> {
    const descriptors: EvidenceDescriptor[] = [], assets: EvidenceAsset[] = [];
    for (const selection of selections) {
      const row = (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor${bytes ? ',bytes' : ''}
        FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`, [snapshot.caseId, selection.evidenceId])).rows[0];
      if (!row || row.descriptor === null) return { status: 'evidence_conflict' };
      const descriptor = this.descriptor(row, snapshot.caseId);
      if (!linked(snapshot, descriptor, true) || descriptor.evidenceRevision !== selection.expectedEvidenceRevision) return { status: 'evidence_conflict' };
      descriptors.push(descriptor);
      if (bytes) assets.push(parseEvidenceAsset({ descriptor, bytes: row.bytes }));
    }
    return { descriptors, assets };
  }
  async readEvidenceCatalogForUser(userId: string, caseId: string): ReturnType<EvidenceRepository['readEvidenceCatalogForUser']> {
    return this.transaction(userId, false, async tx => {
      const entry = await this.caseRow(tx, userId, caseId);
      if (!entry) return { status: 'not_found' };
      const rows = (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor
        FROM ${S}.evidence WHERE case_id=$1 AND descriptor IS NOT NULL ORDER BY evidence_id`, [caseId])).rows;
      const evidence = rows.map(row => this.descriptor(row, caseId)).filter(descriptor => linked(entry.snapshot, descriptor));
      return { status: 'found', catalog: { schemaVersion: '1', caseId, caseRevision: entry.snapshot.revision,
        catalogRevision: entry.catalogRevision, evidence } };
    });
  }
  async readEvidenceForUser(input: EvidenceReadInput): ReturnType<EvidenceRepository['readEvidenceForUser']> {
    const request = structuredClone(input);
    return this.transaction(request.userId, false, async tx => {
      const bound = await this.bound(tx, request);
      if ('status' in bound) return bound;
      const row = (await tx.client.query(`SELECT * FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`,
        [request.caseId, request.evidenceId])).rows[0];
      if (!row || row.descriptor === null) return { status: 'not_found' };
      const descriptor = this.descriptor(row, request.caseId);
      if (!linked(bound.snapshot, descriptor)) return { status: 'not_found' };
      if (descriptor.evidenceRevision !== request.expectedEvidenceRevision) return { status: 'evidence_conflict' };
      return { status: 'found', asset: parseEvidenceAsset({ descriptor, bytes: row.bytes }) };
    });
  }
  async saveEvidenceIfCurrent(input: EvidenceSaveInput): ReturnType<EvidenceRepository['saveEvidenceIfCurrent']> {
    const request = structuredClone(input), image = parseSanitizedEvidenceImage(request.image);
    check(evidenceIdentifier(request.evidenceId) && evidenceIdentifier(request.findingId)
      && evidenceRevision(request.expectedEvidenceRevision, true));
    return this.transaction(request.userId, true, async tx => {
      const bound = await this.bound(tx, request, true);
      if ('status' in bound) return bound;
      if (!linked(bound.snapshot, request)) return { status: 'not_found' };
      const existing = (await tx.client.query(`SELECT revision,finding_id,prepared_at,COALESCE(octet_length(bytes),0) AS size
        FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`, [request.caseId, request.evidenceId])).rows[0];
      const revision = existing ? integer(existing.revision) : 0;
      if (revision !== request.expectedEvidenceRevision || (existing && existing.finding_id !== request.findingId)) return { status: 'evidence_conflict' };
      const descriptor = parseEvidenceDescriptor({ evidenceId: request.evidenceId, evidenceRevision: next(revision),
        caseId: request.caseId, findingId: request.findingId, mediaType: image.mediaType, byteLength: image.byteLength,
        sha256: image.sha256, width: image.width, height: image.height, capturedAt: request.capturedAt,
        preparedAt: request.preparedAt, processingVersion: image.processingVersion });
      check(!existing || instantMicros(descriptor.preparedAt) >= instantMicros(existing.prepared_at));
      const catalogRevision = next(bound.catalogRevision), replaced = existing ? integer(existing.size, true) : 0;
      const freed = await this.exportBytes(tx, request.caseId);
      if ((!existing && tx.quota!.assets >= LIMITS.assets)
        || tx.quota!.bytes - freed - replaced + image.byteLength > LIMITS.bytes) return { status: 'quota_exceeded' };
      await tx.client.query(`INSERT INTO ${S}.evidence(case_id,evidence_id,finding_id,revision,prepared_at,descriptor,bytes)
        VALUES($1,$2,$3,$4,$5,$6::jsonb,$7) ON CONFLICT(case_id,evidence_id) DO UPDATE SET
        revision=EXCLUDED.revision,prepared_at=EXCLUDED.prepared_at,descriptor=EXCLUDED.descriptor,bytes=EXCLUDED.bytes`,
      [request.caseId, request.evidenceId, request.findingId, descriptor.evidenceRevision, descriptor.preparedAt,
        JSON.stringify(descriptor), Buffer.from(image.bytes)]);
      await tx.client.query(`UPDATE ${S}.cases SET catalog_revision=$2 WHERE case_id=$1`, [request.caseId, catalogRevision]);
      await this.invalidateExports(tx, request.caseId);
      await this.quotaDelta(tx, 0, existing ? 0 : 1, 0, image.byteLength - replaced);
      return { status: 'saved', asset: { descriptor, bytes: image.bytes }, catalogRevision };
    });
  }
  async deleteEvidenceIfCurrent(input: EvidenceReadInput): ReturnType<EvidenceRepository['deleteEvidenceIfCurrent']> {
    const request = structuredClone(input);
    return this.transaction(request.userId, true, async tx => {
      const bound = await this.bound(tx, request, true);
      if ('status' in bound) return bound;
      const row = (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor,octet_length(bytes) AS size
        FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`, [request.caseId, request.evidenceId])).rows[0];
      if (!row || row.descriptor === null) return { status: 'not_found' };
      const descriptor = this.descriptor(row, request.caseId);
      if (!linked(bound.snapshot, descriptor)) return { status: 'not_found' };
      if (descriptor.evidenceRevision !== request.expectedEvidenceRevision) return { status: 'evidence_conflict' };
      const evidenceRevision = next(descriptor.evidenceRevision), catalogRevision = next(bound.catalogRevision);
      await tx.client.query(`UPDATE ${S}.evidence SET revision=$3,descriptor=NULL,bytes=NULL WHERE case_id=$1 AND evidence_id=$2`,
        [request.caseId, request.evidenceId, evidenceRevision]);
      await tx.client.query(`UPDATE ${S}.cases SET catalog_revision=$2 WHERE case_id=$1`, [request.caseId, catalogRevision]);
      await this.invalidateExports(tx, request.caseId);
      await this.quotaDelta(tx, 0, 0, 0, -integer(row.size));
      return { status: 'deleted', evidenceRevision, catalogRevision };
    });
  }
  async loadExportSnapshotForUser(input: ExportSnapshotInput): ReturnType<EvidenceRepository['loadExportSnapshotForUser']> {
    const request = structuredClone(input), selections = parseEvidenceSelections(request.selections);
    return this.transaction(request.userId, false, async tx => {
      const bound = await this.bound(tx, request);
      if ('status' in bound) return bound;
      const selected = await this.selected(tx, bound.snapshot, selections, true);
      if ('status' in selected) return selected;
      const answers = await this.answers(tx, request.caseId, request.programId);
      return { status: 'found', snapshot: { snapshot: bound.snapshot, caseFingerprint: caseFingerprint(bound.snapshot),
        answers, answersFingerprint: formAnswersFingerprint(answers), catalogRevision: bound.catalogRevision, assets: selected.assets } };
    });
  }

  private parseExport(row: Row, caseId: string, userId: string): ExportRow {
    const metadata = parseExportArtifactMetadata(row.metadata), bindings = structuredClone(row.bindings) as ExportBindings;
    check(metadata.caseId === caseId && metadata.artifactId === row.artifact_id && typeof row.invalidated === 'boolean'
      && evidenceInstant(row.last_checked_at) && bindings.userId === userId
      && bindings.revision === metadata.caseRevision && bindings.programId === metadata.programId
      && bindings.catalogRevision === metadata.evidenceCatalogRevision && bindings.contextFingerprint === metadata.exportContextId
      && /^[a-f0-9]{64}$/.test(bindings.caseFingerprint)
      && (bindings.answersFingerprint === null || /^[a-f0-9]{64}$/.test(bindings.answersFingerprint)));
    bindings.selections = parseEvidenceSelections(bindings.selections);
    check(bindings.selections.length === metadata.selectedEvidence.length
      && bindings.selections.every((selection, index) => selection.evidenceId === metadata.selectedEvidence[index].evidenceId
        && selection.expectedEvidenceRevision === metadata.selectedEvidence[index].evidenceRevision));
    return { artifactId: row.artifact_id, bindings, metadata, invalidated: row.invalidated,
      lastCheckedAt: row.last_checked_at, byteLength: integer(row.size, true) };
  }
  private async exportRow(tx: Tx, caseId: string, userId: string, column: 'artifact_id' | 'generation_key', value: string): Promise<ExportRow | null> {
    const row = (await tx.client.query(`SELECT artifact_id,bindings,metadata,invalidated,last_checked_at,
      COALESCE(octet_length(bytes),0) AS size FROM ${S}.exports WHERE case_id=$1 AND ${column}=$2`, [caseId, value])).rows[0];
    return row ? this.parseExport(row, caseId, userId) : null;
  }
  private async bindingsCurrent(tx: Tx, entry: CaseRow, saved: ExportRow): Promise<EvidenceRepositoryFailure | null> {
    if (entry.snapshot.revision !== saved.bindings.revision || caseFingerprint(entry.snapshot) !== saved.bindings.caseFingerprint) return { status: 'conflict' };
    if (entry.catalogRevision !== saved.bindings.catalogRevision) return { status: 'evidence_conflict' };
    const answers = await this.answers(tx, entry.snapshot.caseId, saved.bindings.programId);
    if (formAnswersFingerprint(answers) !== saved.bindings.answersFingerprint) return { status: 'answers_conflict' };
    if (saved.invalidated) return { status: 'expired' };
    const selected = await this.selected(tx, entry.snapshot, saved.bindings.selections, false);
    if ('status' in selected) return selected;
    check(selected.descriptors.every((descriptor, index) => descriptor.sha256 === saved.metadata.selectedEvidence[index].sha256
      && descriptor.findingId === saved.metadata.selectedEvidence[index].findingId));
    return null;
  }
  private async checkExportClock(tx: Tx, saved: ExportRow, at: string): Promise<boolean> {
    if (instantMicros(at) < instantMicros(saved.lastCheckedAt)) return false;
    const current = exportCurrent(saved.metadata, at);
    await tx.client.query(`UPDATE ${S}.exports SET last_checked_at=$2,
      invalidated=invalidated OR $3,bytes=CASE WHEN $3 THEN NULL ELSE bytes END WHERE artifact_id=$1`,
    [saved.artifactId, at, !current]);
    if (!current && saved.byteLength) await this.quotaDelta(tx, 0, 0, 0, -saved.byteLength);
    return current;
  }
  async publishExportIfCurrent(input: ExportPublishInput): ReturnType<EvidenceRepository['publishExportIfCurrent']> {
    const request = structuredClone(input), selections = parseEvidenceSelections(request.selections);
    const metadata = parseExportArtifactMetadata(request.artifact.metadata), bytes = request.artifact.bytes;
    validatePdf(bytes, metadata);
    check(/^[a-f0-9]{64}$/.test(request.contextFingerprint) && /^[A-Za-z0-9_-]{8,128}$/.test(request.generationKey)
      && evidenceInstant(request.checkedAt));
    return this.transaction(request.userId, true, async tx => {
      const bound = await this.bound(tx, request, true);
      if ('status' in bound) return bound;
      if (caseFingerprint(bound.snapshot) !== request.expectedCaseFingerprint) return { status: 'conflict' };
      const selected = await this.selected(tx, bound.snapshot, selections, false);
      if ('status' in selected) return selected;
      const answers = await this.answers(tx, request.caseId, request.programId);
      if (formAnswersFingerprint(answers) !== request.expectedAnswersFingerprint) return { status: 'answers_conflict' };
      check(metadata.caseId === request.caseId && metadata.caseRevision === request.revision && metadata.programId === request.programId
        && metadata.evidenceCatalogRevision === request.expectedCatalogRevision && metadata.answerRevision === (answers?.answerRevision ?? 0)
        && metadata.exportContextId === request.contextFingerprint);
      if (answers !== null && (answers.caseRevision !== request.revision || answers.updatedBy !== request.userId
        || answers.answers.some(answer => answer.reviewedBy !== null && answer.reviewedBy !== request.userId)
        || answers.formContextId !== metadata.formContextId || answers.formVersion !== metadata.formVersion
        || answers.mappingVersion !== metadata.mappingVersion || instantMicros(answers.updatedAt) > instantMicros(metadata.generatedAt))) return { status: 'answers_conflict' };
      check(metadata.selectedEvidence.length === selected.descriptors.length && selected.descriptors.every((descriptor, index) => {
        const included = metadata.selectedEvidence[index];
        return included.evidenceId === descriptor.evidenceId && included.evidenceRevision === descriptor.evidenceRevision
          && included.findingId === descriptor.findingId && included.sha256 === descriptor.sha256
          && included.reviewedBy === request.userId && included.reviewedAt === metadata.generatedAt;
      }));
      const at = await this.clock(tx, request.checkedAt);
      check(instantMicros(metadata.generatedAt) <= instantMicros(at));
      if (!exportCurrent(metadata, at)) return { status: 'expired' };
      const existing = await this.exportRow(tx, request.caseId, request.userId, 'generation_key', request.generationKey);
      if (existing) {
        if (existing.invalidated || existing.bindings.contextFingerprint !== request.contextFingerprint
          || existing.bindings.caseFingerprint !== request.expectedCaseFingerprint || existing.bindings.catalogRevision !== request.expectedCatalogRevision
          || existing.bindings.answersFingerprint !== request.expectedAnswersFingerprint || existing.bindings.programId !== request.programId
          || canonicalJson(existing.bindings.selections) !== canonicalJson(selections)
          || !await this.checkExportClock(tx, existing, at)) return { status: 'generation_conflict' };
        return { status: 'reused', artifact: existing.metadata };
      }
      if (tx.quota!.artifacts >= LIMITS.artifacts || tx.quota!.bytes + bytes.byteLength > LIMITS.bytes) return { status: 'quota_exceeded' };
      const bindings: ExportBindings = { userId: request.userId, revision: request.revision, caseFingerprint: request.expectedCaseFingerprint,
        programId: request.programId, catalogRevision: request.expectedCatalogRevision, answersFingerprint: request.expectedAnswersFingerprint,
        contextFingerprint: request.contextFingerprint, selections };
      await tx.client.query(`INSERT INTO ${S}.exports(artifact_id,case_id,generation_key,bindings,metadata,bytes,last_checked_at)
        VALUES($1,$2,$3,$4::jsonb,$5::jsonb,$6,$7)`, [metadata.artifactId, request.caseId, request.generationKey,
        JSON.stringify(bindings), JSON.stringify(metadata), Buffer.from(bytes), at]);
      await this.quotaDelta(tx, 0, 0, 1, bytes.byteLength);
      return { status: 'saved', artifact: metadata };
    });
  }
  async readExportForUser(input: ExportReadInput): ReturnType<EvidenceRepository['readExportForUser']> {
    const request = structuredClone(input);
    return this.transaction(request.userId, false, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId);
      if (!entry) return { status: 'not_found' };
      const saved = await this.exportRow(tx, request.caseId, request.userId, 'artifact_id', request.artifactId);
      if (!saved) return { status: 'not_found' };
      const stale = await this.bindingsCurrent(tx, entry, saved);
      return stale ?? { status: 'found', artifact: saved.metadata };
    });
  }
  async readExportForUserIfCurrent(input: ExportCurrentReadInput): ReturnType<EvidenceRepository['readExportForUserIfCurrent']> {
    const request = structuredClone(input);
    return this.transaction(request.userId, true, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId, true);
      if (!entry) return { status: 'not_found' };
      const saved = await this.exportRow(tx, request.caseId, request.userId, 'artifact_id', request.artifactId);
      if (!saved) return { status: 'not_found' };
      const stale = await this.bindingsCurrent(tx, entry, saved);
      if (stale) return stale;
      if (saved.bindings.contextFingerprint !== request.contextFingerprint) return { status: 'generation_conflict' };
      const at = await this.clock(tx, request.checkedAt);
      if (!await this.checkExportClock(tx, saved, at)) return { status: 'expired' };
      const row = (await tx.client.query(`SELECT bytes FROM ${S}.exports WHERE artifact_id=$1 AND case_id=$2`,
        [request.artifactId, request.caseId])).rows[0];
      check(row && row.bytes instanceof Uint8Array); validatePdf(row.bytes, saved.metadata);
      const after = await this.clock(tx, at);
      if (!await this.checkExportClock(tx, saved, after)) return { status: 'expired' };
      return { status: 'found', artifact: { metadata: saved.metadata, bytes: Uint8Array.from(row.bytes) } };
    });
  }
}
