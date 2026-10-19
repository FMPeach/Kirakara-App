import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';

export function shouldBuild(eventName, previous, current) {
  return eventName === 'workflow_dispatch' ||
    previous.version !== current.version || previous.request !== current.request;
}

if (process.env.GITHUB_ACTIONS === 'true' && process.argv[1]?.endsWith('build-gate.mjs')) {
  const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  function field(path, key, before = false) {
    try {
      const text = before
        ? execFileSync('git', ['show', `${event.before}:${path}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
        : readFileSync(path, 'utf8');
      return JSON.parse(text.replace(/^\uFEFF/, ''))[key];
    } catch (error) {
      if (!before) throw error;
      return undefined; // A newly created branch/file has no previous request.
    }
  }
  const snapshot = before => ({
    version: field('config/package.json', 'version', before),
    request: field('config/actions-build.json', 'request', before),
  });
  const build = shouldBuild(process.env.GITHUB_EVENT_NAME, snapshot(true), snapshot(false));
  appendFileSync(process.env.GITHUB_OUTPUT, `build=${build}\n`);
  console.log(build ? 'Version/build request changed: package App.' : 'Version unchanged: skip Windows build.');
}
