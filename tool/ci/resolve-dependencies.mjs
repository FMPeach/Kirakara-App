import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function checkRuntimeLocks(readJson) {
  const runtime = readJson('native/prebuilt.lock.json');
  const data = readJson('third_party/data.lock.json');
  const missing = [
    ['native/prebuilt.lock.json: imeRuntime', runtime.imeRuntime],
    ['third_party/data.lock.json: zinniaTomoe.binaryPackage', data.zinniaTomoe?.binaryPackage],
    ['third_party/data.lock.json: rime.dataPackage', data.rime?.dataPackage],
  ].filter(([, entry]) => !entry?.url || !/^https:\/\//i.test(entry.url) ||
    !/^[a-f0-9]{64}$/i.test(entry.sha256 ?? '') || !Number.isSafeInteger(entry.size) || entry.size <= 0);
  if (missing.length) throw new Error(`Clean-runner packages are not configured: ${missing.map(([name]) => name).join('; ')}. Publish/configure existing verified packages; CI will not rebuild IMEs or copy a developer .kfe.`);
}

export async function resolveComponent(spec, get, override) {
  if (!/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(spec.repository) ||
      !/^[A-Za-z0-9_.-]+\.ya?ml$/.test(spec.workflow) ||
      typeof spec.branch !== 'string' || !spec.branch || typeof spec.artifact !== 'string' || !spec.artifact) {
    throw new Error('Invalid dependency repository/workflow/branch/artifact configuration.');
  }
  const base = `/repos/${spec.repository}/actions`;
  const requested = override || spec.runId;
  if (requested && !/^[1-9]\d*$/.test(String(requested))) throw new Error('Run ID must be a positive integer.');
  const run = requested
    ? await get(`${base}/runs/${requested}`)
    : (await get(`${base}/workflows/${spec.workflow}/runs?branch=${encodeURIComponent(spec.branch)}&status=success&per_page=50`))
      .workflow_runs.find(value => ['push', 'workflow_dispatch'].includes(value.event));
  if (!run) throw new Error(`No successful build for ${spec.repository}@${spec.branch}; build the dependency first.`);
  if (run.status !== 'completed' || run.conclusion !== 'success' ||
      !['push', 'workflow_dispatch'].includes(run.event) || run.head_branch !== spec.branch ||
      run.head_repository?.full_name !== spec.repository ||
      run.path?.split('@')[0] !== `.github/workflows/${spec.workflow}` ||
      !/^[a-f0-9]{40}$/i.test(run.head_sha)) {
    throw new Error(`Dependency run ${run.id} is not a successful trusted branch build of ${spec.repository}.`);
  }
  const { artifacts } = await get(`${base}/runs/${run.id}/artifacts?per_page=100`);
  const matches = artifacts.filter(value => value.name === spec.artifact);
  if (matches.length !== 1 || matches[0].expired ||
      !Number.isFinite(Date.parse(matches[0].expires_at)) || Date.parse(matches[0].expires_at) <= Date.now()) {
    throw new Error(`Artifact ${spec.artifact} is missing/expired in run ${run.id}; rebuild the dependency. No older build will be substituted.`);
  }
  return { repository: spec.repository, branch: spec.branch, workflow: spec.workflow,
    runId: String(run.id), commit: run.head_sha, runAttempt: String(run.run_attempt),
    artifactId: String(matches[0].id), artifactName: spec.artifact, url: run.html_url };
}

async function main() {
  const readJson = path => JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
  checkRuntimeLocks(readJson); // Fail on Linux before allocating a Windows runner.
  const config = readJson('config/actions-dependencies.json');
  if (config.schemaVersion !== 1) throw new Error('Unsupported actions dependency schema.');
  const token = process.env.GH_TOKEN;
  if (!token) throw new Error('An Actions read token is required.');
  const get = async path => {
    const response = await fetch(`https://api.github.com${path}`, {
      headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28' }, signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) throw new Error(`GitHub API ${response.status} for ${path}. Check Actions read access; private cross-repository artifacts require DEPENDENCY_ARTIFACTS_TOKEN.`);
    return response.json();
  };
  const [show, helper] = await Promise.all([
    resolveComponent(config.show, get, process.env.SHOW_RUN_ID),
    resolveComponent(config.helper, get, process.env.HELPER_RUN_ID),
  ]);
  mkdirSync('build/actions-test', { recursive: true });
  writeFileSync('build/actions-test/dependencies.json', `${JSON.stringify({ schemaVersion: 1, show, helper }, null, 2)}\n`);
  for (const [key, value] of Object.entries({ show, helper })) {
    appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${JSON.stringify(value)}\n`);
  }
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,
    `## Selected prebuilt dependencies\n\n${[show, helper].map(value => `- ${value.repository}: [run ${value.runId}](${value.url}), commit \`${value.commit}\``).join('\n')}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
