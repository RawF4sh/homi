import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import type { UploadEvidenceResponse } from '../../src/api/write-evidence.ts';
import type { EvidenceCatalog } from '../../src/evidence/types.ts';
import type { ExportArtifactMetadata } from '../../src/exports/types.ts';
import { createFormAnswerContext } from '../../src/forms/form-answers.ts';
import { loadRuntimeBenefitsBundle } from '../../src/programs/runtime-bundle.ts';
import type { CaseSnapshot } from '../../src/types.ts';
import { readFixture } from '../memory/fixture.ts';
import type { Scenario, WorkloadMetrics } from '../memory/workload.ts';
import { AGGREGATE_CASE_ID, API_ORIGIN, CASE_ID, OTHER_TOKEN, TOKEN, baseRequest, parseScenario,
  scenarioFixture, syntheticDiagnostic, syntheticDraft } from './protocol.ts';

export interface LinuxWorkloadReport {
  schemaVersion: '1'; kind: 'workload'; scenario: Scenario; status: 'passed' | 'failed'; iterations: number;
  workload: WorkloadMetrics; assertions: Record<string, boolean>; iterationElapsedMs: number[];
}
const privateResponse = (response: Response) => response.headers.get('cache-control') === 'no-store'
  && response.headers.get('x-content-type-options') === 'nosniff';

export async function digestResponse(response: Response, maximum: number) {
  if (!response.body) throw new Error('Missing private response body.');
  const digest = createHash('sha256'); let length = 0;
  const prefix = Buffer.alloc(8); let prefixLength = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (length + value.length > maximum) throw new Error('Private response exceeds its contract.');
      digest.update(value); length += value.length;
      const copied = Math.min(prefix.length - prefixLength, value.length);
      prefix.set(value.subarray(0, copied), prefixLength); prefixLength += copied;
    }
    return { bytes: length, sha256: digest.digest('hex'), prefix: prefix.subarray(0, prefixLength) };
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}

export async function runLinuxWorkload(scenario: Scenario, directory: string, transport: typeof fetch = fetch): Promise<LinuxWorkloadReport> {
  parseScenario(scenario);
  const iterations = scenario === 'pdf-repeat-16mp' || scenario === 'upload-repeat-16mp' ? 3 : 1;
  const report: LinuxWorkloadReport = { schemaVersion: '1', kind: 'workload', scenario, status: 'failed', iterations,
    workload: { inputBytes: 0, selectedEvidenceBytes: 0, selectedEvidencePixels: 0 }, assertions: {}, iterationElapsedMs: [] };
  const check = (name: string, value: boolean) => { report.assertions[name] = (report.assertions[name] ?? true) && value; };
  const post = (route: string, body: unknown, token = TOKEN) => transport(`${API_ORIGIN}/v1/${route}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(body), redirect: 'error', signal: AbortSignal.timeout(120_000),
  });
  const json = async <T>(route: string, body: unknown, token = TOKEN, expectedStatus = 200): Promise<T> => {
    const response = await post(route, body, token);
    check('privateNoStore', privateResponse(response));
    if (response.status !== expectedStatus) {
      console.error(JSON.stringify({ kind: 'synthetic-http-status', route, expectedStatus, status: response.status }));
      await response.body?.cancel();
      throw new Error('Unexpected synthetic API status.');
    }
    return await response.json() as T;
  };
  const failure = async (route: string, body: unknown, status: number, code: string, token = TOKEN) => {
    const value = await json<{ schemaVersion: string; error: { code: string } }>(route, body, token, status);
    return value.schemaVersion === '1' && value.error?.code === code;
  };
  const ordinaryRead = async () => {
    const value = await json<CaseSnapshot>('read-case', { schemaVersion: '1', caseId: CASE_ID });
    check('ordinaryReadAccepted', value.caseId === CASE_ID && value.revision === 1);
  };
  try {
    if (scenario.startsWith('upload-') || scenario === 'reject-oversize') {
      const created = await json<CaseSnapshot>('create-case', syntheticDraft(1));
      check('httpCaseCreated', created.caseId === CASE_ID && created.revision === 1);
    }
    await ordinaryRead();
    check('crossOwnerCaseDenied', await failure('read-case', { schemaVersion: '1', caseId: CASE_ID }, 404, 'CASE_NOT_FOUND', OTHER_TOKEN));
    check('invalidSessionDenied', await failure('read-case', { schemaVersion: '1', caseId: CASE_ID }, 401, 'UNAUTHENTICATED', 'invalid-synthetic-token'));

    if (scenario.startsWith('pdf-')) {
      const { name, count } = scenarioFixture(scenario);
      const fixture = await readFixture(directory, name);
      report.workload = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: fixture.bytes.length * count,
        selectedEvidencePixels: fixture.metadata.width * fixture.metadata.height * count };
      const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1');
      const form = await bundle.loadFormTemplate('scfhp-eaa');
      if (!form || form.template.pageCount !== 5) throw new Error('Bundled form unavailable.');
      const body = { ...baseRequest, programId: 'scfhp-eaa',
        expectedFormContextId: createFormAnswerContext(form.template).formContextId, expectedAnswerRevision: 0,
        expectedEvidenceCatalogRevision: count, generationKey: 'synthetic-linux-memory-retry',
        selectedEvidence: Array.from({ length: count }, (_, index) => ({ evidenceId: `synthetic-photo-${index + 1}`,
          expectedEvidenceRevision: 1, reviewedForExport: true })) };
      let artifactId: string | undefined;
      for (let index = 0; index < iterations; index++) {
        const started = performance.now();
        const [artifact] = await Promise.all([json<ExportArtifactMetadata>('create-draft-export', body), ordinaryRead()]);
        check('draftOnly', artifact.status === 'draft' && artifact.warnings.includes('INCOMPLETE_DRAFT')
          && artifact.warnings.includes('NOT_SUBMITTED') && artifact.warnings.includes('POLICY_CURRENTNESS_UNKNOWN'));
        check('exactPagesAndSelection', artifact.pageCount === 5 + count && artifact.selectedEvidence.length === count);
        check('retryIdentityPreserved', artifactId === undefined || artifactId === artifact.artifactId);
        check('boundToExactEvidence', artifact.selectedEvidence.every((selected, selectedIndex) =>
          selected.evidenceId === `synthetic-photo-${selectedIndex + 1}` && selected.evidenceRevision === 1 && selected.sha256 === fixture.metadata.sha256));
        artifactId = artifact.artifactId;
        const response = await post('download-draft-export', { ...baseRequest, artifactId });
        check('privateNoStore', privateResponse(response));
        check('downloadAccepted', response.status === 200 && response.headers.get('content-type') === 'application/pdf');
        const downloaded = await digestResponse(response, 32 * 1024 * 1024);
        check('pdfMagic', downloaded.prefix.subarray(0, 5).toString('ascii') === '%PDF-');
        check('downloadDigestMatches', downloaded.bytes === artifact.byteLength && downloaded.sha256 === artifact.sha256);
        report.iterationElapsedMs.push(Math.ceil(performance.now() - started));
      }
      check('crossOwnerArtifactDenied', await failure('download-draft-export', { ...baseRequest, artifactId }, 404, 'ARTIFACT_NOT_FOUND', OTHER_TOKEN));
    } else if (scenario.startsWith('upload-')) {
      const { name } = scenarioFixture(scenario);
      const fixture = await readFixture(directory, name), fullPixels = name === 'full16mp.jpg';
      report.workload = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: 0,
        selectedEvidencePixels: fixture.metadata.width * fixture.metadata.height };
      check('fixtureInputBounds', fixture.bytes.length >= (fullPixels ? 6 : 7.5) * 1024 * 1024 && fixture.bytes.length <= 8 * 1024 * 1024);
      check('fixturePixelCoverage', report.workload.selectedEvidencePixels === (fullPixels ? 16_000_000 : 7_290_000));
      const body = { ...baseRequest, evidenceId: 'synthetic-photo-1', findingId: 'synthetic-finding', capturedAt: null,
        imageBase64: fixture.bytes.toString('base64') };
      let previousHash: string | undefined;
      for (let index = 0; index < iterations; index++) {
        const started = performance.now(), revision = index + 1;
        const [uploaded] = await Promise.all([json<UploadEvidenceResponse>('upload-evidence', { ...body,
          expectedCatalogRevision: index, expectedEvidenceRevision: index }), ordinaryRead()]);
        const descriptor = uploaded.evidence;
        report.workload.selectedEvidenceBytes = descriptor.byteLength;
        check('uploadAccepted', uploaded.catalogRevision === revision && uploaded.caseRevision === 1 && descriptor.evidenceRevision === revision);
        check('exactDimensions', descriptor.width === fixture.metadata.width && descriptor.height === fixture.metadata.height);
        check('pngMetadata', descriptor.mediaType === 'image/png' && descriptor.processingVersion === 'evidence-png-v1');
        check('replacementDigestStable', previousHash === undefined || previousHash === descriptor.sha256); previousHash = descriptor.sha256;
        const response = await post('download-evidence', { ...baseRequest, expectedCatalogRevision: revision,
          evidenceId: 'synthetic-photo-1', expectedEvidenceRevision: revision });
        check('privateNoStore', privateResponse(response));
        check('previewAccepted', response.status === 200 && response.headers.get('content-type') === 'image/png');
        const downloaded = await digestResponse(response, 24 * 1024 * 1024);
        check('previewDigestMatches', downloaded.bytes === descriptor.byteLength && downloaded.sha256 === descriptor.sha256);
        check('pngMagic', downloaded.prefix.equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])));
        const catalog = await json<EvidenceCatalog>('list-evidence', baseRequest);
        check('singleCurrentPhoto', catalog.catalogRevision === revision && catalog.caseRevision === 1
          && catalog.evidence.length === 1 && catalog.evidence[0].evidenceRevision === revision && catalog.evidence[0].sha256 === descriptor.sha256);
        report.iterationElapsedMs.push(Math.ceil(performance.now() - started));
      }
      check('crossOwnerArtifactDenied', await failure('download-evidence', { ...baseRequest, expectedCatalogRevision: iterations,
        evidenceId: 'synthetic-photo-1', expectedEvidenceRevision: iterations }, 404, 'ARTIFACT_NOT_FOUND', OTHER_TOKEN));
    } else {
      const started = performance.now(), fixture = await readFixture(directory, 'oversize.png');
      const solid = await readFixture(directory, 'solid.png');
      report.workload = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: solid.bytes.length * 2,
        selectedEvidencePixels: solid.metadata.width * solid.metadata.height * 2 };
      const body = { ...baseRequest, expectedCatalogRevision: 0, evidenceId: 'synthetic-photo-1', expectedEvidenceRevision: 0,
        findingId: 'synthetic-finding', capturedAt: null };
      check('pixelLimitRejected', await failure('upload-evidence', { ...body, imageBase64: fixture.bytes.toString('base64') }, 422, 'INVALID_IMAGE'));
      check('inputByteLimitRejected', await failure('upload-evidence', { ...body, imageBase64: Buffer.alloc(8 * 1024 * 1024 + 1).toString('base64') }, 400, 'INVALID_REQUEST'));
      check('aggregateLimitRejected', await failure('create-draft-export', { ...baseRequest, caseId: AGGREGATE_CASE_ID, programId: 'scfhp-eaa',
        expectedFormContextId: 'a'.repeat(64), expectedAnswerRevision: 0, expectedEvidenceCatalogRevision: 2,
        generationKey: 'synthetic-linux-rejected-attempt', selectedEvidence: [1, 2].map(index => ({
          evidenceId: `synthetic-photo-${index}`, expectedEvidenceRevision: 1, reviewedForExport: true })) }, 422, 'EXPORT_REVIEW_REQUIRED'));
      const catalog = await json<EvidenceCatalog>('list-evidence', baseRequest);
      check('noPartialUpload', catalog.catalogRevision === 0 && catalog.evidence.length === 0);
      report.iterationElapsedMs.push(Math.ceil(performance.now() - started));
    }
    await ordinaryRead();
    check('workerCompleted', true);
  } catch (error) { syntheticDiagnostic('http-workload', error); check('workerCompleted', false); }
  report.status = Object.values(report.assertions).every(Boolean) && report.iterationElapsedMs.length === iterations ? 'passed' : 'failed';
  return report;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4) { console.error('Synthetic HTTP workload arguments are invalid.'); process.exitCode = 1; }
  else Promise.resolve().then(() => runLinuxWorkload(parseScenario(process.argv[2]), process.argv[3])).then(report => {
    console.log(JSON.stringify(report)); if (report.status !== 'passed') process.exitCode = 1;
  }, () => { console.error('Synthetic HTTP workload failed.'); process.exitCode = 1; });
}
