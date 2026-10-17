import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import { assertWorkloadMode, LONG_SESSION_INTERVAL_MS, LONG_SESSION_ITERATIONS, parseWorkloadMode } from '../tool/linux-memory/protocol.ts';
import { artifactIsFresh, createProgressAcknowledger, runLinuxWorkload, runPacedLongSession,
  type LinuxWorkloadProgress } from '../tool/linux-memory/workload.ts';

const progress: LinuxWorkloadProgress = { schemaVersion: '1', kind: 'workload-progress', scenario: 'pdf-repeat-16mp',
  mode: 'long', iteration: 1, plannedIterations: 12, iterationElapsedMs: 20, elapsedMs: 20 };

test('long-session choices are fixed, bounded and restricted to the maximum-image repeat workloads', () => {
  assert.equal(parseWorkloadMode(), 'boundary'); assert.equal(parseWorkloadMode('long'), 'long');
  assert.equal(LONG_SESSION_ITERATIONS, 12); assert.equal(LONG_SESSION_INTERVAL_MS, 10_000);
  assertWorkloadMode('pdf-repeat-16mp', 'long'); assertWorkloadMode('upload-repeat-16mp', 'long');
  for (const mode of ['short', 'forever', '1000', '']) assert.throws(() => parseWorkloadMode(mode));
  assert.throws(() => assertWorkloadMode('pdf-solid-16mp', 'long'));
  assert.throws(() => assertWorkloadMode('reject-oversize', 'long'));
});

test('twelve paced operations respect heavy-request refill without shortening slow operations', async () => {
  let clock = 200; const starts: number[] = [], waits: number[] = [];
  const result = await runPacedLongSession(async index => {
    starts.push(clock); clock += index === 2 ? 14_000 : 2_000;
  }, { now: () => clock, wait: async milliseconds => { waits.push(milliseconds); clock += milliseconds; } });
  assert.equal(starts.length, 12); assert.equal(result.starts.length, 12); assert.equal(result.durations.length, 12);
  assert.ok(starts.every((start, index) => index === 0 || start - starts[index - 1] >= 10_000));
  assert.equal(starts[3] - starts[2], 14_000);
  assert.equal(result.elapsedMs, 116_000); assert.ok(waits.every(value => value === 8_000));
});

test('a failed repeated operation stops the session immediately without fabricating later iterations', async () => {
  let clock = 0, calls = 0;
  await assert.rejects(runPacedLongSession(async index => {
    calls++; clock += 10;
    if (index === 3) throw new Error('synthetic repeat failed');
  }, { now: () => clock, wait: async milliseconds => { clock += milliseconds; } }), /synthetic repeat failed/);
  assert.equal(calls, 4);
});

test('reported iteration starts use the exact paced timestamp even when each clock read advances', async () => {
  let clock = 100; const actualStarts: number[] = [];
  const result = await runPacedLongSession(async (_index, started) => {
    assert.equal(started, clock - 1); actualStarts.push(started); clock += 7;
  }, { now: () => clock++, wait: async milliseconds => { clock += milliseconds; } });
  assert.deepEqual(result.starts, actualStarts.map(start => start - 100));
  assert.ok(actualStarts.every((start, index) => index === 0 || start - actualStarts[index - 1] >= 10_000));
});

test('cancellation interrupts pacing and does not issue the next heavy operation', async () => {
  let clock = 0, calls = 0; const controller = new AbortController();
  await assert.rejects(runPacedLongSession(async () => { calls++; clock += 10; }, {
    signal: controller.signal, now: () => clock, wait: async (_milliseconds, signal) => {
      assert.equal(signal, controller.signal); controller.abort(); signal?.throwIfAborted();
    },
  }), { name: 'AbortError' });
  assert.equal(calls, 1);
});

test('a waiter that returns early cannot turn an underpaced session into success', async () => {
  let clock = 0, calls = 0;
  await assert.rejects(runPacedLongSession(async () => { calls++; clock += 10; }, {
    now: () => clock, wait: async () => { clock++; },
  }), /pacing clock/);
  assert.equal(calls, 1);
});

test('progress acknowledgement is registered before publication and excludes stale acknowledgements', async () => {
  const signals = new EventEmitter(); let published = 0;
  const acknowledger = createProgressAcknowledger(value => {
    assert.deepEqual(value, progress); published++; signals.emit('SIGUSR2');
  }, signals);
  signals.emit('SIGUSR2');
  await acknowledger.report(progress); await acknowledger.report(progress);
  assert.equal(published, 2); acknowledger.dispose(); assert.equal(signals.listenerCount('SIGUSR2'), 0);
  await assert.rejects(acknowledger.report(progress), /acknowledgement state/);
});

test('an unacknowledged checkpoint fails and leaves no signal listener or pending timer', async () => {
  const signals = new EventEmitter(); let published = 0;
  const acknowledger = createProgressAcknowledger(() => { published++; }, signals, 10);
  await assert.rejects(acknowledger.report(progress), /timed out/);
  assert.equal(published, 1); acknowledger.dispose(); assert.equal(signals.listenerCount('SIGUSR2'), 0);
  assert.throws(() => createProgressAcknowledger(() => {}, signals, 30_001));
});

test('checkpoint wait rejects concurrent publication and can be cancelled during teardown', async () => {
  const signals = new EventEmitter(); const acknowledger = createProgressAcknowledger(() => {}, signals);
  const pending = acknowledger.report(progress);
  await assert.rejects(acknowledger.report(progress), /acknowledgement state/);
  acknowledger.dispose(); await assert.rejects(pending, /cancelled/);
  assert.equal(signals.listenerCount('SIGUSR2'), 0);
});

test('publication failures release the pending checkpoint instead of retaining its deadline', async () => {
  const signals = new EventEmitter(); const acknowledger = createProgressAcknowledger(() => { throw new Error('output failed'); }, signals);
  await assert.rejects(acknowledger.report(progress), /output failed/);
  await assert.rejects(acknowledger.report(progress), /output failed/); acknowledger.dispose();
});

test('PDF freshness checks reject expiration, future generation, invalid dates and earlier policy deadlines', () => {
  const artifact = { generatedAt: '2026-10-18T10:00:00.000Z', expiresAt: '2026-10-18T10:15:00.000Z', recheckAfter: null };
  const generated = Date.parse(artifact.generatedAt), expiry = Date.parse(artifact.expiresAt);
  assert.equal(artifactIsFresh(artifact, generated), true); assert.equal(artifactIsFresh(artifact, expiry - 1), true);
  assert.equal(artifactIsFresh(artifact, expiry), false); assert.equal(artifactIsFresh(artifact, generated - 1), false);
  assert.equal(artifactIsFresh({ ...artifact, expiresAt: 'invalid' }, generated), false);
  assert.equal(artifactIsFresh({ ...artifact, recheckAfter: '2026-10-18T10:01:00.000Z' }, generated + 60_000), false);
  assert.equal(artifactIsFresh(artifact, NaN), false);
});

test('an aborted long workload reports failure, no completed iterations and no plateau claim', async t => {
  t.mock.method(console, 'error', () => {});
  const controller = new AbortController(); controller.abort();
  const transport: typeof fetch = async () => { throw new Error('aborted workload must not send HTTP'); };
  const report = await runLinuxWorkload('pdf-repeat-16mp', '/not-read', transport, { mode: 'long', signal: controller.signal });
  assert.equal(report.status, 'failed'); assert.equal(report.mode, 'long'); assert.equal(report.iterations, 12);
  assert.deepEqual(report.iterationElapsedMs, []); assert.deepEqual(report.iterationStartElapsedMs, []);
  assert.equal(report.renderRequests, 0); assert.equal(report.assertions.workerCompleted, false);
  assert.equal(Object.keys(report).some(key => /plateau|stableMemory|leakFree/i.test(key)), false);
});
