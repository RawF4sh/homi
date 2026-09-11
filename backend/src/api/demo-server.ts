import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { demoProgram } from '../../fixtures/demo-program.ts';
import { matchPrograms } from '../matcher.ts';
import { readSharedScenarios } from '../shared-fixtures.ts';
import type { ProgramDefinition } from '../types.ts';
import { createMatchingServer } from './http-server.ts';
import { MemoryCaseRepository } from './memory-case-repository.ts';

export function createDemoServer(fixturePath?: string) {
  if (process.env.NODE_ENV === 'production') throw new Error('The demo server is for local fictional development only.');
  const scenarios = readSharedScenarios(fixturePath);
  const aliceToken = randomBytes(32).toString('base64url');
  const bobToken = randomBytes(32).toString('base64url');
  const tokens = new Map([[aliceToken, 'demo-alice'], [bobToken, 'demo-bob']]);
  const startedAt = new Date();
  const program: ProgramDefinition = {
    ...structuredClone(demoProgram),
    recheckAfter: new Date(startedAt.getTime() + 60 * 60 * 1000).toISOString(),
  };
  const bobCase = { ...structuredClone(scenarios[0].case), caseId: 'demo-case-bob' };
  const entries = [
    ...scenarios.map(scenario => ({ userId: 'demo-alice', snapshot: scenario.case })),
    { userId: 'demo-bob', snapshot: bobCase },
  ];
  for (const { snapshot } of entries) {
    matchPrograms(snapshot, [program], { evaluatedAt: startedAt.toISOString(), evaluationDate: startedAt.toISOString().slice(0, 10) });
  }
  const cases = new MemoryCaseRepository(entries);
  const server = createMatchingServer({
    authenticate: async token => tokens.has(token) ? { userId: tokens.get(token)! } : null,
    cases,
    loadRegistry: async () => [structuredClone(program)],
    now: () => new Date(),
    allowDemoPrograms: true,
  });
  return { server, cases, sessions: { alice: aliceToken, bob: bobToken },
    caseIds: { alice: scenarios.map(scenario => scenario.case.caseId), bob: bobCase.caseId } };
}

async function main() {
  let port = 8787;
  let fixturePath: string | undefined;
  let machine = false;
  for (let index = 2; index < process.argv.length; index++) {
    const argument = process.argv[index];
    if (argument === '--machine') machine = true;
    else if (argument === '--fixtures' && process.argv[index + 1]) fixturePath = process.argv[++index];
    else if (argument === '--port' && /^\d+$/.test(process.argv[index + 1] ?? '')) port = Number(process.argv[++index]);
    else throw new Error('Use --fixtures PATH, --port 0..65535, and optionally --machine.');
  }
  if (!Number.isSafeInteger(port) || port < 0 || port > 65535) throw new Error('Invalid local port.');
  const demo = createDemoServer(fixturePath);
  await new Promise<void>((resolve, reject) => {
    demo.server.once('error', reject);
    demo.server.listen(port, '127.0.0.1', resolve);
  });
  const address = demo.server.address();
  if (!address || typeof address === 'string') throw new Error('Local listener was not created.');
  const ready = { type: 'demo-ready', endpoint: `http://127.0.0.1:${address.port}/v1/match-case`, ...demo.sessions, caseIds: demo.caseIds };
  if (machine) console.log(JSON.stringify(ready));
  else {
    console.log('Fictional local API. Cases/results are in memory and disappear on exit.');
    console.log(`Endpoint: ${ready.endpoint}`);
    console.log(`Alice demo bearer token: ${ready.alice}`);
    console.log(`Bob demo bearer token: ${ready.bob}`);
    console.log(`Alice case IDs: ${ready.caseIds.alice.join(', ')}`);
    console.log(`Bob case ID: ${ready.caseIds.bob}`);
  }
  const stop = () => { demo.server.close(); demo.server.closeAllConnections(); };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => { console.error('Local demo could not start. Check the fixture path, port, and development environment.'); process.exitCode = 1; });
}
