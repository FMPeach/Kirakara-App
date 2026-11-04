import test from 'node:test';
import assert from 'node:assert/strict';
import { checkRuntimeLocks, resolveComponent, resolveComponentForPackaging,
  resolveReleaseFallback } from './resolve-dependencies.mjs';
import { shouldBuild } from './build-gate.mjs';

const spec = { repository: 'FMPeach/Kirakara-Show', branch: 'Actions-Test',
  workflow: 'build-show.yml', artifact: 'kirakara-show-windows-x64', runId: null };
const helperSpec = { repository: 'FMPeach/ChunK-Helper', branch: 'main',
  workflow: 'build-helper.yml', artifact: '*-windows-x64', runId: null,
  releaseFallback: { asset: '*-windows-x64.zip' } };
const trustedHelperRun = { head_branch: 'main',
  head_repository: { full_name: 'FMPeach/ChunK-Helper' },
  path: '.github/workflows/build-helper.yml' };
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

function releaseFixture(changeRelease = {}, changeAsset = {}) {
  const asset = { id: 202, name: 'ChunK-Helper-v0.2.0-windows-x64.zip',
    state: 'uploaded', size: 12345, digest: `sha256:${'b'.repeat(64)}`, ...changeAsset };
  return { id: 303, tag_name: 'v0.2', draft: false, prerelease: false,
    html_url: 'https://github.com/FMPeach/ChunK-Helper/releases/tag/v0.2',
    assets: [asset], ...changeRelease };
}

function addRelease(get, releases = [releaseFixture()]) {
  return async path => path.includes('/releases?') ? releases : get(path);
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
  assert.equal(result.source, 'actions'); assert.equal(result.runId, '42');
  assert.equal(result.artifactId, '101'); assert.equal(result.commit, commit);
});

test('uses a verified Release asset when the latest Helper artifact expired', async () => {
  const { get, requests } = fixture(trustedHelperRun, { expired: true });
  const result = await resolveComponentForPackaging(helperSpec, addRelease(get));
  assert.deepEqual({ source: result.source, releaseTag: result.releaseTag,
    assetId: result.assetId, assetSha256: result.assetSha256 },
  { source: 'release', releaseTag: 'v0.2', assetId: '202', assetSha256: 'B'.repeat(64) });
  assert.ok(requests.some(path => path.includes('/artifacts?')));
});

test('uses a verified Release asset when Helper has no successful Actions build', async () => {
  const requests = [];
  const get = async path => {
    requests.push(path);
    if (path.includes('/releases?')) return [releaseFixture()];
    if (path.includes('/workflows/')) return { workflow_runs: [] };
    throw new Error(`Unexpected request: ${path}`);
  };
  const result = await resolveComponentForPackaging(helperSpec, get);
  assert.equal(result.source, 'release');
  assert.equal(result.assetName, 'ChunK-Helper-v0.2.0-windows-x64.zip');
});

test('an explicitly selected Helper run never silently falls back to a Release', async () => {
  const { get, requests } = fixture(trustedHelperRun, { expired: true });
  await assert.rejects(resolveComponentForPackaging(helperSpec, addRelease(get), '42'), /missing\/expired/);
  assert.equal(requests.some(path => path.includes('/releases?')), false);
});

test('an untrusted Helper build never silently falls back to a Release', async () => {
  const { get, requests } = fixture({ ...trustedHelperRun,
    head_repository: { full_name: 'someone/ChunK-Helper' } });
  await assert.rejects(resolveComponentForPackaging(helperSpec, addRelease(get)), /trusted branch build/);
  assert.equal(requests.some(path => path.includes('/releases?')), false);
});

test('Release fallback rejects missing digest and ambiguous matching assets', async () => {
  await assert.rejects(resolveReleaseFallback(helperSpec,
    async () => [releaseFixture({}, { digest: null })]), /incomplete identity/);
  const release = releaseFixture();
  release.assets.push({ ...release.assets[0], id: 203, name: '纯K助手-v0.3.0-windows-x64.zip' });
  await assert.rejects(resolveReleaseFallback(helperSpec, async () => [release]), /multiple assets/);
});

test('Release fallback skips drafts and Releases without a matching Windows package', async () => {
  const result = await resolveReleaseFallback(helperSpec, async () => [
    releaseFixture({ draft: true }),
    releaseFixture({ id: 304, tag_name: 'v0.1' }, { name: 'sources.zip' }),
    releaseFixture({ id: 305, tag_name: 'v0.2' }),
  ]);
  assert.equal(result.releaseId, '305');
  assert.equal(result.releaseTag, 'v0.2');
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
