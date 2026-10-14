import assert from 'node:assert/strict';
import test from 'node:test';
import { resolve } from 'node:path';
import { apiContainerArgs, localDockerEnvironment, parseLinuxOptions, runCommand } from '../tool/linux-memory/container-harness.ts';

const output = resolve('local-artifacts/linux-test.json');
const args = ['--socket', '/tmp/owned-docker.sock', '--architecture', 'amd64', '--emulation', 'qemu-system', '--output', output];
test('Linux profile requires explicit local engine and architecture; report cannot escape ignored artifacts', () => {
  assert.equal(parseLinuxOptions(args).scenarios.length, 9);
  for (const bad of [[], [...args, '--socket', '/another.sock'], [...args, '--unknown', 'yes'],
    args.map(value => value === '/tmp/owned-docker.sock' ? 'tcp://remote:2375' : value),
    args.map(value => value === output ? '/tmp/report.json' : value),
    args.map(value => value === 'amd64' ? 'guess' : value)]) {
    assert.throws(() => parseLinuxOptions(bad));
  }
  assert.deepEqual(parseLinuxOptions([...args, '--scenario', 'pdf-near24mb']).scenarios, ['pdf-near24mb']);
});
test('Docker subprocesses receive isolated local engine configuration without inherited credentials', () => {
  const env = localDockerEnvironment('/tmp/a.sock', '/tmp/private-config');
  assert.deepEqual(Object.keys(env).sort(), ['DOCKER_BUILDKIT', 'DOCKER_CONFIG', 'DOCKER_HOST', 'PATH']);
  assert.equal(env.DOCKER_HOST, 'unix:///tmp/a.sock');
  assert.equal(env.DOCKER_CONFIG, '/tmp/private-config');
});
test('measured API has a decimal 500 MB hard limit, no swap, production heaps and no host exposure', () => {
  const command = apiContainerArgs('api', 'isolated', 'fixtures', 'local-image', 'run1');
  const value = (flag: string) => command[command.indexOf(flag) + 1];
  assert.equal(value('--memory'), '500000000'); assert.equal(value('--memory-swap'), '500000000');
  assert.equal(value('--cpus'), '1'); assert.equal(value('--cap-drop'), 'ALL');
  assert.equal(value('--user'), '1000:1000'); assert.equal(value('--security-opt'), 'no-new-privileges');
  assert.equal(value('--mount'), 'type=volume,src=fixtures,dst=/lab,readonly');
  assert.ok(command.includes('--read-only'));
  for (const forbidden of ['--privileged', '--publish', '-p', '--volume', '-v', '--env-file', '--device']) assert.ok(!command.includes(forbidden));
  assert.deepEqual(command.slice(-4), ['node', '--max-old-space-size=64', '--max-semi-space-size=1', 'tool/linux-memory/server.ts']);
});
test('command runner preserves failure/timeout, bounds output and never evaluates shell syntax', async () => {
  const env = { PATH: process.env.PATH };
  const literal = await runCommand(process.execPath, ['-e', 'process.stdout.write(process.argv[1])', '$(do-not-run); `literal`'], env);
  assert.equal(literal.code, 0); assert.equal(literal.stdout, '$(do-not-run); `literal`');
  assert.equal((await runCommand(process.execPath, ['-e', 'process.exit(17)'], env)).code, 17);
  const timed = await runCommand(process.execPath, ['-e', 'setInterval(()=>{},1000)'], env, 30);
  assert.equal(timed.timedOut, true); assert.notEqual(timed.code, 0);
  const overflow = await runCommand(process.execPath, ['-e', "process.stdout.write('x'.repeat(3*1024*1024))"], env);
  assert.equal(overflow.code, -1);
  const abort = new AbortController();
  const interrupted = runCommand(process.execPath, ['-e', 'setInterval(()=>{},1000)'], env, 5_000, abort.signal);
  abort.abort();
  assert.equal((await interrupted).code, -1);
});
