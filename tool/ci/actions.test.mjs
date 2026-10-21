import test from 'node:test';
import assert from 'node:assert/strict';
import { checkRuntimeLocks, resolveComponent } from './resolve-dependencies.mjs';
import { shouldBuild } from './build-gate.mjs';

const spec = { repository: 'FMPeach/Kirakara-Show', branch: 'Actions-Test',
  workflow: 'build-show.yml', artifact: 'kirakara-show-windows-x64', runId: null };
const commit = 'a'.repeat(40);
function fixture(changeRun = {}, changeArtifact = {}) {
  const run = { id: 42, run_attempt: 1, status: 'completed', conclusion: 'success',
    event: 'push', head_branch: spec.branch, head_sha: commit,
    head_repository: { full_name: spec.repository },
    path: '.github/workflows/build-show.yml', html_url: 'https://github.com/example/run/42', ...changeRun };
  const artifact = { id: 101, name: spec.artifact, expired: false,
    expires_at: '2099-01-01T00:00:00Z', ...changeArtifact };
  const requests = [];
  return { requests, get: async path => {
    requests.push(path);
    if (path.includes('/artifacts?')) return { artifacts: [artifact] };
    if (path.includes('/workflows/')) return { workflow_runs: [run] };
    return run;
  } };
}

test('manual request builds even without a version change', () => {
  assert.equal(shouldBuild('workflow_dispatch', {}, {}), true);
});
test('ordinary metadata edit does not start Windows build', () => {
  assert.equal(shouldBuild('push', { version: 'v0.1 Beta', request: '1' },
    { version: 'v0.1 Beta', request: '1', name: 'Changed' }), false);
});
test('version change starts one build; arbitrary display label is preserved', () => {
  assert.equal(shouldBuild('push', { version: 'v0.1 Beta', request: '1' },
    { version: 'v0.2 Beta', request: '1' }), true);
});
test('changed request or initial branch builds', () => {
  assert.equal(shouldBuild('push', { version: '1', request: '1' }, { version: '1', request: '2' }), true);
  assert.equal(shouldBuild('push', {}, { version: '1', request: '1' }), true);
});
test('selects a successful dependency and freezes artifact ID/commit', async () => {
  const { get } = fixture();
  const result = await resolveComponent(spec, get);
  assert.equal(result.runId, '42'); assert.equal(result.artifactId, '101'); assert.equal(result.commit, commit);
});

for (const name of ['纯K助手-v0.2.0-windows-x64', 'ChunK-Helper-v0.3.0-windows-x64', 'chunk-helper-windows-x64']) {
  test(`selects versioned or legacy artifact ${name} and records its actual name`, async () => {
    const { get } = fixture({}, { name });
    const result = await resolveComponent({ ...spec, artifact: '*-windows-x64' }, get);
    assert.equal(result.artifactId, '101');
    assert.equal(result.artifactName, name);
  });
}

test('artifact name punctuation remains literal rather than a regular expression', async () => {
  const name = 'Helper.v0.2+[release]-windows-x64';
  const result = await resolveComponent({ ...spec, artifact: name }, fixture({}, { name }).get);
  assert.equal(result.artifactName, name);
  await assert.rejects(resolveComponent({ ...spec, artifact: 'Helper.v0.2-windows-x64' },
    fixture({}, { name: 'HelperXv0X2-windows-x64' }).get), /missing\/expired/);
});

test('versioned artifact matching still rejects the wrong platform', async () => {
  await assert.rejects(resolveComponent({ ...spec, artifact: '*-windows-x64' },
    fixture({}, { name: '纯K助手-v0.2.0-linux-x64' }).get), /missing\/expired/);
});

test('multiple matching artifacts fail instead of choosing one arbitrarily', async () => {
  const { get } = fixture();
  const ambiguous = async path => path.includes('/artifacts?') ? { artifacts: [
    { id: 101, name: '纯K助手-v0.2.0-windows-x64', expired: false, expires_at: '2099-01-01T00:00:00Z' },
    { id: 102, name: '纯K助手-v0.3.0-windows-x64', expired: false, expires_at: '2099-01-01T00:00:00Z' },
  ] } : get(path);
  await assert.rejects(resolveComponent({ ...spec, artifact: '*-windows-x64' }, ambiguous), /missing\/expired/);
});
test('explicit run ID does not search latest builds', async () => {
  const { get, requests } = fixture();
  await resolveComponent(spec, get, '42');
  assert.equal(requests[0], '/repos/FMPeach/Kirakara-Show/actions/runs/42');
  assert.equal(requests.length, 2);
});
test('configured run ID is honored', async () => {
  const { get, requests } = fixture();
  await resolveComponent({ ...spec, runId: '42' }, get);
  assert.ok(requests[0].endsWith('/runs/42'));
});
for (const [name, change] of Object.entries({
  'failed build': { conclusion: 'failure' }, 'unfinished build': { status: 'in_progress' },
  'other branch': { head_branch: 'main' }, 'untrusted PR': { event: 'pull_request' },
  'fork build': { head_repository: { full_name: 'someone/fork' } },
  'other workflow': { path: '.github/workflows/other.yml' }, 'invalid source SHA': { head_sha: 'main' },
})) {
  test(`rejects ${name}`, async () => {
    await assert.rejects(resolveComponent(spec, fixture(change).get, '42'), /trusted branch build/);
  });
}
for (const [name, change] of Object.entries({
  expired: { expired: true }, 'expired timestamp': { expires_at: '2000-01-01T00:00:00Z' },
  'invalid expiry': { expires_at: 'not-a-date' },
  missing: { name: 'different-name' },
})) {
  test(`rejects ${name} artifact without falling back`, async () => {
    const { get, requests } = fixture({}, change);
    await assert.rejects(resolveComponent(spec, get), /missing\/expired/);
    assert.equal(requests.length, 2);
  });
}
test('no successful builds provides actionable failure', async () => {
  await assert.rejects(resolveComponent(spec, async () => ({ workflow_runs: [] })), /build the dependency first/);
});
test('invalid run ID is rejected without an API request', async () => {
  await assert.rejects(resolveComponent(spec, async () => { throw new Error('must not call'); }, '1;echo'), /positive integer/);
});
test('invalid repository is rejected before using credentials', async () => {
  await assert.rejects(resolveComponent({ ...spec, repository: '../malicious' }, fixture().get), /Invalid dependency/);
});
test('clean-runner runtime locks must have downloadable verified packages', () => {
  const entry = { url: 'https://example.com/package.zip', size: 123, sha256: 'a'.repeat(64) };
  const files = { 'native/prebuilt.lock.json': { imeRuntime: entry },
    'third_party/data.lock.json': { zinniaTomoe: { binaryPackage: entry }, rime: { dataPackage: entry } } };
  checkRuntimeLocks(path => files[path]);
  files['native/prebuilt.lock.json'].imeRuntime = null;
  assert.throws(() => checkRuntimeLocks(path => files[path]), /imeRuntime/);
  files['native/prebuilt.lock.json'].imeRuntime = { ...entry, url: 'D:\\local.zip' };
  assert.throws(() => checkRuntimeLocks(path => files[path]), /imeRuntime/);
});
