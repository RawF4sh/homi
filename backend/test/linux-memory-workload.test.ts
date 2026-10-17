import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
import { AUTH, OTHER, OTHER_TOKEN, OWNER, TOKEN, parseScenario, syntheticAuthFetch } from '../tool/linux-memory/protocol.ts';
import { allocatorArenaMax, parseCgroupEvents, parseCgroupInteger } from '../tool/linux-memory/server.ts';
import { digestResponse, runLinuxWorkload } from '../tool/linux-memory/workload.ts';

test('container telemetry requires finite byte limits and complete nonduplicated cgroup counters', () => {
  assert.equal(parseCgroupInteger('500000000\n'), 500_000_000);
  assert.equal(parseCgroupInteger('0\n'), 0);
  for (const value of ['max\n', '-1', '0.5', ' 2', '1\n\n', '9007199254740992']) assert.throws(() => parseCgroupInteger(value));
  assert.deepEqual(parseCgroupEvents('low 0\nhigh 0\nmax 3\noom 0\noom_kill 0\noom_group_kill 0\n'),
    { low: 0, high: 0, max: 3, oom: 0, oom_kill: 0, oom_group_kill: 0 });
  for (const value of ['low 0\nhigh 0\nmax 0\noom 0\n',
    'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\nlow 1\n',
    'low 0\nhigh 0\nmax 0\noom 0\noom_kill -1\n']) assert.throws(() => parseCgroupEvents(value));
});

test('allocator telemetry rejects values that do not represent a canonical decimal startup setting', () => {
  assert.equal(allocatorArenaMax('2'), 2); assert.equal(allocatorArenaMax('4'), 4); assert.equal(allocatorArenaMax('0'), 0);
  for (const value of ['', '0x2', ' 2', '2 ', '2\n', '+2', '02', '2.0', '-2', 'NaN', '9007199254740992']) {
    assert.equal(allocatorArenaMax(value), null);
  }
});

test('synthetic auth transport exercises provider parsing and separates fictional owners', async () => {
  const authenticate = createSupabaseAuthenticator(AUTH, syntheticAuthFetch);
  assert.deepEqual(await authenticate(TOKEN), { userId: OWNER });
  assert.deepEqual(await authenticate(OTHER_TOKEN), { userId: OTHER });
  assert.equal(await authenticate('unknown-token'), null);
  await assert.rejects(syntheticAuthFetch('https://external.example/auth/v1/user', { method: 'GET' }));
  assert.throws(() => parseScenario('anything-else'));
});

test('separate HTTP client hashes every streamed byte and handles split magic prefixes', async () => {
  const bytes = Buffer.from('%PDF-1.7\nsynthetic-packet\n');
  const stream = new ReadableStream<Uint8Array>({ start(controller) {
    for (const part of [bytes.subarray(0, 2), bytes.subarray(2, 5), bytes.subarray(5)]) controller.enqueue(part);
    controller.close();
  } });
  const result = await digestResponse(new Response(stream), bytes.length);
  assert.equal(result.bytes, bytes.length);
  assert.equal(result.sha256, createHash('sha256').update(bytes).digest('hex'));
  assert.deepEqual(result.prefix, bytes.subarray(0, 8));
});

test('HTTP client stops oversized binary bodies and cancels the reader', async () => {
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(Buffer.alloc(9)); },
    cancel() { cancelled = true; } });
  await assert.rejects(digestResponse(new Response(stream), 8));
  assert.equal(cancelled, true);
});

test('HTTP failures produce a failed bounded report without exposing response details', async t => {
  const diagnostics: unknown[][] = [];
  t.mock.method(console, 'error', (...args: unknown[]) => { diagnostics.push(args); });
  const transport: typeof fetch = async (input, options) => {
    assert.equal(input, 'http://api:8788/v1/read-case');
    assert.equal(options?.redirect, 'error');
    assert.ok(options?.signal);
    return new Response('private-provider-diagnostic', { status: 503 });
  };
  const report = await runLinuxWorkload('pdf-solid-16mp', '/not-read', transport);
  assert.equal(report.status, 'failed'); assert.equal(report.assertions.workerCompleted, false);
  assert.equal(report.iterationElapsedMs.length, 0);
  assert.equal(JSON.stringify(report).includes('private-provider-diagnostic'), false);
  assert.equal(JSON.stringify(diagnostics).includes('private-provider-diagnostic'), false);
  assert.equal(diagnostics.length, 2);
});
