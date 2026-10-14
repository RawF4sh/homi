import assert from 'node:assert/strict';
import test from 'node:test';
import { evaluateLinuxMemoryScenario, type LinuxMemoryScenarioInput } from '../tool/linux-memory/report.ts';

function snapshot() {
  return { schemaVersion: '1', kind: 'memory', rssBytes: 204_800_000, maxRssKiB: 250_000, maxRssBytes: 256_000_000,
    cgroup: { version: 2, currentBytes: 220_000_000, peakBytes: 300_000_000, limitBytes: 499_998_720,
      swapMaxBytes: 0, cpuMax: '100000 100000', events: { low: 0, high: 0, max: 0, oom: 0, oom_kill: 0 } } };
}
function inspection(running: boolean) {
  return { Id: 'a'.repeat(64), Config: { User: 'node', Env: ['DO_NOT_EXPORT=this-private-value'] },
    HostConfig: { Memory: 500_000_000, MemorySwap: 500_000_000, NanoCpus: 1_000_000_000, ReadonlyRootfs: true,
      Privileged: false, PublishAllPorts: false, CapDrop: ['ALL'], CapAdd: [], Binds: [], VolumesFrom: [], Devices: [],
      DeviceRequests: [], Sysctls: {}, PortBindings: {}, NetworkMode: 'synthetic-isolated-network', PidMode: '',
      IpcMode: 'private', UTSMode: '', SecurityOpt: ['no-new-privileges'], RestartPolicy: { Name: 'no', MaximumRetryCount: 0 } },
    Mounts: [{ Type: 'volume', RW: false, Source: '/unreturned/private/path', Destination: '/lab' }],
    NetworkSettings: { Ports: { '8788/tcp': null } },
    State: { Status: running ? 'running' : 'exited', Running: running, OOMKilled: false, Dead: false, Error: '', ExitCode: 0 } };
}
function inputFor(scenario: LinuxMemoryScenarioInput['scenario'] = 'pdf-solid-16mp') {
  const common = { privateNoStore: true, ordinaryReadAccepted: true, crossOwnerCaseDenied: true, invalidSessionDenied: true, workerCompleted: true };
  const pdf = { draftOnly: true, exactPagesAndSelection: true, retryIdentityPreserved: true, boundToExactEvidence: true,
    downloadAccepted: true, pdfMagic: true, downloadDigestMatches: true, crossOwnerArtifactDenied: true };
  const upload = { httpCaseCreated: true, fixtureInputBounds: true, fixturePixelCoverage: true, uploadAccepted: true,
    exactDimensions: true, pngMetadata: true, replacementDigestStable: true, previewAccepted: true, previewDigestMatches: true,
    pngMagic: true, singleCurrentPhoto: true, crossOwnerArtifactDenied: true };
  const rejection = { httpCaseCreated: true, pixelLimitRejected: true, inputByteLimitRejected: true, aggregateLimitRejected: true, noPartialUpload: true };
  const iterations = ['pdf-repeat-16mp', 'upload-repeat-16mp'].includes(scenario) ? 3 : 1;
  const inputBytes = ['pdf-near24mb', 'pdf-repeat-16mp'].includes(scenario) ? 24_500_000
    : scenario.startsWith('upload-') ? 8_000_000 : 65_536;
  const selectedEvidenceBytes = scenario.startsWith('upload-') ? 21_000_000 : inputBytes * (scenario === 'pdf-six-16mp' ? 6 : 1);
  return { scenario, architecture: 'amd64' as 'amd64' | 'arm64',
    ready: { schemaVersion: '1', kind: 'ready', runtime: { node: '24.22.0', platform: 'linux', arch: 'x64', uid: 1000,
      execArgv: ['--max-old-space-size=64', '--max-semi-space-size=1'] }, baseline: snapshot() }, memory: snapshot(),
    workload: { schemaVersion: '1', kind: 'workload', scenario, status: 'passed', iterations,
      workload: { inputBytes, selectedEvidenceBytes, selectedEvidencePixels: scenario === 'pdf-six-16mp' ? 15_996_000
        : scenario === 'upload-near8mb-jpeg' ? 7_290_000 : scenario === 'reject-oversize' ? 32_000_000 : 16_000_000 },
      iterationElapsedMs: Array<number>(iterations).fill(125),
      assertions: { ...common, ...(scenario.startsWith('pdf-') ? pdf : scenario.startsWith('upload-') ? upload : rejection) } as Record<string, boolean> },
    clientExitCode: 0 as number | null, apiHealthyAfterWorkload: true,
    beforeStopInspect: inspection(true), afterStopInspect: inspection(false) };
}

test('all nine complete Linux workload reports pass with page-rounded cgroup limit', () => {
  const scenarios: LinuxMemoryScenarioInput['scenario'][] = ['pdf-solid-16mp', 'pdf-alpha-16mp', 'pdf-six-16mp', 'pdf-near24mb',
    'upload-near8mb-jpeg', 'upload-16mp-jpeg', 'upload-repeat-16mp', 'pdf-repeat-16mp', 'reject-oversize'];
  for (const scenario of scenarios) {
    const result = evaluateLinuxMemoryScenario(inputFor(scenario));
    assert.equal(result.status, 'passed', `${scenario}: ${result.failures}`);
    assert.deepEqual(result.cgroupEventsDelta, { low: 0, high: 0, max: 0, oom: 0, oom_kill: 0 });
  }
});

test('arm64 must be explicitly requested, and report metrics are detached and contain no Docker secrets or paths', () => {
  const input = inputFor(); input.architecture = 'arm64'; input.ready.runtime.arch = 'arm64';
  const report = evaluateLinuxMemoryScenario(input);
  assert.equal(report.status, 'passed');
  input.ready.runtime.execArgv[0] = 'modified'; input.memory.cgroup.events.max = 99;
  input.workload.assertions.workerCompleted = false;
  assert.equal(report.memory?.cgroup.events.max, 0);
  assert.equal(report.workload?.assertions.workerCompleted, true);
  assert.deepEqual(report.runtime?.execArgv, ['--max-old-space-size=64', '--max-semi-space-size=1']);
  assert.doesNotMatch(JSON.stringify(report), /DO_NOT_EXPORT|private-value|private\/path|synthetic-isolated-network|a{64}/);
});

test('omitted optional empty Docker fields are safe, but explicit device cgroup rules are not', () => {
  const input = inputFor();
  for (const inspection of [input.beforeStopInspect, input.afterStopInspect]) {
    for (const key of ['CapAdd', 'Binds', 'VolumesFrom', 'Devices', 'DeviceRequests', 'Sysctls', 'PortBindings']) {
      Reflect.deleteProperty(inspection.HostConfig, key);
    }
  }
  assert.equal(evaluateLinuxMemoryScenario(input).status, 'passed');
  Object.assign(input.beforeStopInspect.HostConfig, { DeviceCgroupRules: ['a *:* rwm'] });
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
});

test('RSS and cgroup headroom are independently required and the exact target is allowed', () => {
  const input = inputFor(); input.memory.cgroup.peakBytes = 400_000_000;
  assert.equal(evaluateLinuxMemoryScenario(input).status, 'passed');
  input.memory.cgroup.peakBytes++;
  assert.deepEqual(evaluateLinuxMemoryScenario(input).failures, ['cgroup_headroom_target_exceeded']);
  input.memory.cgroup.peakBytes = 300_000_000;
  input.memory.maxRssKiB = 390_626; input.memory.maxRssBytes = 390_626 * 1024;
  assert.deepEqual(evaluateLinuxMemoryScenario(input).failures, ['rss_headroom_target_exceeded']);
  input.memory.maxRssKiB = 500_000; input.memory.maxRssBytes = 512_000_000;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('service_reference_exceeded'));
  input.memory.cgroup.peakBytes = input.memory.cgroup.limitBytes;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('service_reference_exceeded'));
});

const metricFailures: [string, (input: ReturnType<typeof inputFor>) => void, string][] = [
  ['actual foreign architecture', i => { i.ready.runtime.arch = 'arm64'; }, 'runtime_invalid'],
  ['non-Linux runtime', i => { i.ready.runtime.platform = 'darwin'; }, 'runtime_invalid'],
  ['unpinned Node', i => { i.ready.runtime.node = '24.21.0'; }, 'runtime_invalid'],
  ['forced GC flag', i => { i.ready.runtime.execArgv.push('--expose-gc'); }, 'runtime_invalid'],
  ['wrong V8 heap limit', i => { i.ready.runtime.execArgv[0] = '--max-old-space-size=128'; }, 'runtime_invalid'],
  ['root runtime', i => { i.ready.runtime.uid = 0; }, 'runtime_invalid'],
  ['KiB conversion mismatch', i => { i.memory.maxRssBytes++; }, 'final_memory_invalid'],
  ['current exceeds peak', i => { i.memory.cgroup.currentBytes = 300_000_001; }, 'final_memory_invalid'],
  ['zero peak', i => { i.memory.cgroup.peakBytes = 0; }, 'final_memory_invalid'],
  ['cgroup v1', i => { i.memory.cgroup.version = 1; }, 'final_memory_invalid'],
  ['limit rounded above configured', i => { i.memory.cgroup.limitBytes = 500_000_001; }, 'final_memory_invalid'],
  ['limit excessively rounded down', i => { i.memory.cgroup.limitBytes = 499_900_000; }, 'final_memory_invalid'],
  ['swap enabled', i => { i.memory.cgroup.swapMaxBytes = 1; }, 'final_memory_invalid'],
  ['CPU unlimited', i => { i.memory.cgroup.cpuMax = 'max 100000'; }, 'final_memory_invalid'],
  ['CPU exceeds one core', i => { i.memory.cgroup.cpuMax = '200000 100000'; }, 'final_memory_invalid'],
  ['existing baseline OOM', i => { i.ready.baseline.cgroup.events.oom = 1; i.memory.cgroup.events.oom = 1; }, 'oom_detected'],
  ['new OOM without kill', i => { i.memory.cgroup.events.oom = 1; }, 'oom_detected'],
  ['new OOM kill', i => { i.memory.cgroup.events.oom_kill = 1; }, 'oom_detected'],
  ['counter reset', i => { i.ready.baseline.cgroup.events.max = 1; }, 'memory_counters_regressed'],
  ['peak reset', i => { i.ready.baseline.cgroup.peakBytes = 310_000_000; }, 'memory_counters_regressed'],
];
for (const [name, change, failure] of metricFailures) test(`fails closed for ${name}`, () => {
  const input = inputFor(); change(input);
  const result = evaluateLinuxMemoryScenario(input);
  assert.equal(result.status, 'failed'); assert.ok(result.failures.includes(failure), result.failures.join(','));
});

test('absent memory, partial cgroup events, and snapshot error reports cannot pass', () => {
  const input: LinuxMemoryScenarioInput = inputFor();
  for (const memory of [undefined, null, { schemaVersion: '1', kind: 'memory', status: 'failed' },
    { ...snapshot(), cgroup: { ...snapshot().cgroup, events: { oom: 0, oom_kill: 0 } } }]) {
    input.memory = memory;
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('final_memory_invalid'));
  }
  input.memory = snapshot(); input.ready = undefined;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('baseline_memory_invalid'));
});

const containerFailures: [string, (inspect: ReturnType<typeof inspection>) => void][] = [
  ['unbounded memory', i => { i.HostConfig.Memory = 0; }],
  ['swap allowance', i => { i.HostConfig.MemorySwap = 1_000_000_000; }],
  ['wrong CPU budget', i => { i.HostConfig.NanoCpus = 2_000_000_000; }],
  ['writable root', i => { i.HostConfig.ReadonlyRootfs = false; }],
  ['privileged', i => { i.HostConfig.Privileged = true; }],
  ['retained capabilities', i => { i.HostConfig.CapDrop = []; }],
  ['missing no-new-privileges', i => { i.HostConfig.SecurityOpt = []; }],
  ['root configured user', i => { i.Config.User = '0:1000'; }],
  ['host networking', i => { i.HostConfig.NetworkMode = 'host'; }],
  ['shared peer networking', i => { i.HostConfig.NetworkMode = 'container:peer'; }],
  ['host PID namespace', i => { i.HostConfig.PidMode = 'host'; }],
  ['automatic restart', i => { i.HostConfig.RestartPolicy.Name = 'always'; }],
  ['host bind mount', i => { i.Mounts[0].Type = 'bind'; }],
  ['writable volume', i => { i.Mounts[0].RW = true; }],
  ['automatic host ports', i => { i.HostConfig.PublishAllPorts = true; }],
];
for (const [name, change] of containerFailures) test(`rejects ${name} before or after the measured workload`, () => {
  for (const phase of ['beforeStopInspect', 'afterStopInspect'] as const) {
    const input = inputFor(); change(input[phase]);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
  }
});

test('explicit ports, host Binds, device requests, and sysctls fail even with otherwise safe inspect fields', () => {
  for (const unsafe of [ { PortBindings: { '8788/tcp': [{ HostPort: '8788' }] } }, { Binds: ['/tmp:/tmp'] },
    { DeviceRequests: [{ Count: -1 }] }, { Devices: [{ PathOnHost: '/dev/mem' }] }, { Sysctls: { 'net.ipv4.ip_forward': '1' } } ]) {
    const input = inputFor(); Object.assign(input.beforeStopInspect.HostConfig, unsafe);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
  }
  const input = inputFor();
  Object.assign(input.beforeStopInspect.NetworkSettings, { Ports: { '8788/tcp': [{ HostPort: '8788' }] } });
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
});

test('OOM-killed, dead, replaced, unhealthy, and nonzero-exit containers cannot be rescued by good workload JSON', () => {
  const changes: [(input: ReturnType<typeof inputFor>) => void, string][] = [
    [i => { i.beforeStopInspect.State.Running = false; }, 'api_not_running'],
    [i => { i.afterStopInspect.State.OOMKilled = true; }, 'api_exit_failed'],
    [i => { i.afterStopInspect.State.ExitCode = 137; }, 'api_exit_failed'],
    [i => { i.afterStopInspect.State.Dead = true; }, 'api_exit_failed'],
    [i => { i.afterStopInspect.Id = 'b'.repeat(64); }, 'container_identity_mismatch'],
    [i => { i.clientExitCode = null; }, 'client_exit_failed'],
    [i => { i.clientExitCode = 1; }, 'client_exit_failed'],
    [i => { i.apiHealthyAfterWorkload = false; }, 'api_unhealthy'],
  ];
  for (const [change, failure] of changes) {
    const input = inputFor(); change(input);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes(failure));
  }
});

test('a killed API retains its actual exit and OOM status even when no final memory report exists', () => {
  const input = inputFor();
  input.beforeStopInspect.State.Running = false; input.beforeStopInspect.State.Status = 'exited';
  input.beforeStopInspect.State.OOMKilled = true; input.beforeStopInspect.State.ExitCode = 137;
  input.afterStopInspect.State.OOMKilled = true; input.afterStopInspect.State.ExitCode = 137;
  const result = evaluateLinuxMemoryScenario({ ...input, memory: undefined, clientExitCode: 1, apiHealthyAfterWorkload: false });
  assert.equal(result.status, 'failed'); assert.equal(result.memory, null);
  assert.deepEqual(result.api, {
    beforeStop: { running: false, exitCode: 137, oomKilled: true },
    afterStop: { running: false, exitCode: 137, oomKilled: true },
  });
  assert.ok(result.failures.includes('api_exit_failed'));
  assert.ok(result.failures.includes('final_memory_invalid'));
});

test('missing assertions, failed assertions, and truncated repeats remain failures', () => {
  for (const name of ['boundToExactEvidence', 'crossOwnerCaseDenied', 'downloadDigestMatches', 'workerCompleted']) {
    const input = inputFor(); delete input.workload.assertions[name];
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_assertions_incomplete'));
  }
  const input = inputFor('pdf-repeat-16mp');
  input.workload.assertions.downloadDigestMatches = false;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_failed'));
  input.workload.assertions.downloadDigestMatches = true; input.workload.status = 'failed';
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_failed'));
  input.workload.status = 'passed'; input.workload.iterationElapsedMs.pop();
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_invalid'));
  input.workload.iterationElapsedMs.push(125); input.workload.workload.selectedEvidencePixels = 1;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_invalid'));
});

test('ordinary safety failures preserve measured peaks for diagnosis without accepting a partial success', () => {
  const input = inputFor(); input.clientExitCode = 1;
  input.memory.cgroup.peakBytes = 450_000_000; input.workload.assertions = {};
  const result = evaluateLinuxMemoryScenario(input);
  assert.equal(result.status, 'failed'); assert.equal(result.memory?.cgroup.peakBytes, 450_000_000);
  assert.deepEqual(result.failures, ['cgroup_headroom_target_exceeded', 'client_exit_failed', 'workload_assertions_incomplete']);
});
