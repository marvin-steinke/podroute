const assert = require('node:assert/strict');
const { test } = require('node:test');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, rmSync, readFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const {
  parseVersion, compareVersions, nextVersion, successfulMainCI, renovateMerge, peelTag, botOnlyHistory,
  autoTag, resolveRelease, verifyImage, publish, registryImage,
} = require('./release.cjs');

test('stable versions are strict and compared numerically', () => {
  for (const tag of ['1.2.3', 'v01.2.3', 'v1.02.3', 'v1.2.03', 'v1.2', 'v1.2.3-rc.1', 'v1.2.3+meta', 'v1.2.3\n']) {
    assert.equal(parseVersion(tag), null, tag);
  }
  assert.deepEqual(parseVersion('v0.0.0'), [0n, 0n, 0n]);
  assert.equal(compareVersions('v1.10.0', 'v1.9.9'), 1);
  assert.equal(compareVersions('v2.0.0', 'v10.0.0'), -1);
  assert.equal(compareVersions('v1.0.0', 'v1.0.0'), 0);
  assert.throws(() => compareVersions('bad', 'v1.0.0'));
});

test('bootstrap, patch increments and manual version baselines', () => {
  assert.equal(nextVersion([]), 'v1.0.0');
  assert.equal(nextVersion(['v1.0.0-rc.1', 'other']), 'v1.0.0');
  assert.equal(nextVersion(['v1.9.9', 'v1.10.0', 'v1.2.99']), 'v1.10.1');
  assert.equal(nextVersion(['v1.0.9']), 'v1.0.10');
  assert.equal(nextVersion(['v1.0.9', 'v2.0.0']), 'v2.0.1');
  assert.equal(nextVersion(['v1.0.9', 'v1.1.0']), 'v1.1.1');
  assert.equal(nextVersion(['v1.0.9007199254740993']), 'v1.0.9007199254740994');
});

const repository = 'owner/podroute';
const sha = 'merged-sha';
const run = {
  event: 'push', status: 'completed', conclusion: 'success', head_branch: 'main',
  head_repository: { full_name: repository }, path: '.github/workflows/ci.yml',
};

test('only successful trusted main push CI is eligible', () => {
  assert.equal(successfulMainCI(run, repository), true);
  for (const conclusion of ['failure', 'cancelled', 'skipped', 'neutral', null]) {
    assert.equal(successfulMainCI({ ...run, conclusion }, repository), false);
  }
  for (const patch of [
    { event: 'pull_request' }, { event: 'workflow_dispatch' }, { status: 'in_progress' },
    { head_branch: 'feature' }, { head_repository: { full_name: 'fork/podroute' } },
    { path: '.github/workflows/untrusted.yml' }, { head_repository: null },
  ]) assert.equal(successfulMainCI({ ...run, ...patch }, repository), false);
});

const pull = {
  number: 10, merged: true, base: { ref: 'main', repo: { full_name: repository } },
  head: { repo: { full_name: repository } }, user: { login: 'renovate[bot]' },
  merged_by: { login: 'renovate[bot]' }, merge_commit_sha: sha, commits: 1,
};
const commits = [{ author: { login: 'renovate[bot]' } }];

test('PR author, merger, every commit author and exact merge must match', () => {
  assert.equal(renovateMerge(pull, commits, sha, repository), true);
  for (const patch of [
    { merged: false }, { user: { login: 'human' } }, { merged_by: { login: 'human' } },
    { merged_by: null }, { merge_commit_sha: 'other' }, { commits: 2 },
    { base: { ref: 'develop', repo: { full_name: repository } } },
    { base: { ref: 'main', repo: { full_name: 'other/repo' } } },
    { head: { repo: { full_name: 'fork/podroute' } } },
  ]) assert.equal(renovateMerge({ ...pull, ...patch }, commits, sha, repository), false);
  assert.equal(renovateMerge(pull, [], sha, repository), false);
  assert.equal(renovateMerge(pull, [{ author: null }], sha, repository), false);
  assert.equal(renovateMerge(pull, [{ author: { login: 'human' } }], sha, repository), false);
  assert.equal(renovateMerge({ ...pull, commits: 2 }, [...commits, { author: { login: 'human' } }], sha, repository), false);
});

test('lightweight and nested annotated tags resolve to commits only', async () => {
  const objects = { outer: { type: 'tag', sha: 'inner' }, inner: { type: 'commit', sha } };
  const github = { rest: { git: { getTag: async ({ tag_sha }) => ({ data: { object: objects[tag_sha] } }) } } };
  assert.equal(await peelTag(github, {}, { type: 'commit', sha }), sha);
  assert.equal(await peelTag(github, {}, { type: 'tag', sha: 'outer' }), sha);
  await assert.rejects(peelTag(github, {}, { type: 'tree', sha }), /commit/);
  objects.inner = { type: 'tag', sha: 'outer' };
  await assert.rejects(peelTag(github, {}, { type: 'tag', sha: 'outer' }), /cycle/);
});

test('unreleased human changes stop automatic patch releases', async () => {
  const eligible = async commit => commit.startsWith('bot-');
  assert.equal(await botOnlyHistory(['bot-1', 'bot-2'], eligible), null);
  assert.equal(await botOnlyHistory(['bot-1', 'human', 'bot-2'], eligible), 'human');
  assert.equal(await botOnlyHistory(['unknown', 'bot-2'], eligible), 'unknown');
});

function fixture(testContext, history = ['base', 'bot-first'], initialTags = ['v1.0.0']) {
  const cwd = process.cwd();
  const directory = mkdtempSync(join(tmpdir(), 'podroute-release-'));
  process.chdir(directory);
  testContext.after(() => { process.chdir(cwd); rmSync(directory, { recursive: true, force: true }); });
  const git = (...args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', '-q', '-b', 'main');
  const shas = [];
  for (const name of history) {
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', name);
    shas.push(git('rev-parse', 'HEAD'));
  }
  git('update-ref', 'refs/remotes/origin/main', shas.at(-1));
  const tags = initialTags.map(name => ({ name, sha: shas[0] }));
  const dispatches = [];
  const created = [];
  const messages = [];
  const currentRun = { ...run, id: 1, head_sha: shas.at(-1) };
  const rest = {
    git: {
      listMatchingRefs: () => {},
      createRef: async ({ ref, sha: commit }) => {
        const name = ref.slice('refs/tags/'.length);
        if (tags.some(tag => tag.name === name)) throw Object.assign(new Error('Exists'), { status: 422 });
        tags.push({ name, sha: commit });
        created.push({ name, sha: commit });
      },
    },
    actions: {
      getWorkflowRun: async () => ({ data: currentRun }),
      listJobsForWorkflowRun: () => {},
      createWorkflowDispatch: async request => dispatches.push(request),
    },
    repos: { listPullRequestsAssociatedWithCommit: () => {} },
    pulls: {
      get: async ({ pull_number }) => ({ data: {
        ...pull, number: pull_number, merge_commit_sha: shas[pull_number],
        merged_by: { login: history[pull_number].startsWith('bot-') ? 'renovate[bot]' : 'human' },
      } }),
      listCommits: () => {},
    },
  };
  const github = {
    rest,
    paginate: async (method, args) => {
      if (method === rest.git.listMatchingRefs) return tags.map(tag => ({ ref: `refs/tags/${tag.name}`, object: { type: 'commit', sha: tag.sha } }));
      if (method === rest.actions.listJobsForWorkflowRun) return [{ name: 'CI Gate', conclusion: 'success' }];
      if (method === rest.repos.listPullRequestsAssociatedWithCommit) return [{
        number: shas.indexOf(args.commit_sha), merge_commit_sha: args.commit_sha, base: { ref: 'main' },
      }];
      if (method === rest.pulls.listCommits) return commits;
      throw new Error('Unexpected paginated request');
    },
  };
  const core = {
    info: message => messages.push(message),
    summary: { addRaw: () => ({ write: async () => {} }) },
  };
  const context = { repo: { owner: 'owner', repo: 'podroute' }, payload: { workflow_run: { id: 1 } } };
  return { github, core, context, tags, shas, dispatches, created, messages, currentRun, git };
}

test('allocator creates one patch and reruns reuse its tag', async testContext => {
  const state = fixture(testContext);
  await autoTag(state);
  await autoTag(state);
  assert.deepEqual(state.created, [{ name: 'v1.0.1', sha: state.shas.at(-1) }]);
  assert.equal(state.dispatches.length, 2);
  assert.equal(state.dispatches[0].inputs.tag, 'v1.0.1');
  assert.equal(state.dispatches[0].ref, 'main');
});

test('allocator bootstraps v1.0.0 only after an eligible bot merge', async testContext => {
  const state = fixture(testContext, ['base', 'bot-first'], []);
  await autoTag(state);
  assert.equal(state.created[0].name, 'v1.0.0');
});

test('human changes or human merges pause tagging', async testContext => {
  const state = fixture(testContext, ['base', 'bot-first', 'human-feature', 'bot-last']);
  await autoTag(state);
  assert.equal(state.created.length, 0);
  assert.match(state.messages.at(-1), /unreleased human/);
  state.currentRun.head_sha = state.shas[2];
  await autoTag(state);
  assert.equal(state.created.length, 0);
  assert.match(state.messages.at(-1), /not a Renovate-only bot merge/);
});

test('a later manual major tag establishes the next patch baseline', async testContext => {
  const state = fixture(testContext, ['base', 'human-feature', 'bot-last']);
  state.tags.push({ name: 'v2.0.0', sha: state.shas[1] });
  await autoTag(state);
  assert.equal(state.created[0].name, 'v2.0.1');
});

test('failed dispatch can retry without a second version bump', async testContext => {
  const state = fixture(testContext);
  const dispatch = state.github.rest.actions.createWorkflowDispatch;
  state.github.rest.actions.createWorkflowDispatch = async () => { throw new Error('Dispatch unavailable'); };
  await assert.rejects(autoTag(state), /Dispatch unavailable/);
  assert.equal(state.created.length, 1);
  state.github.rest.actions.createWorkflowDispatch = dispatch;
  await autoTag(state);
  assert.equal(state.created.length, 1);
  assert.equal(state.dispatches[0].inputs.tag, 'v1.0.1');
});

test('tag collision refreshes instead of overwriting a version', async testContext => {
  const state = fixture(testContext);
  const create = state.github.rest.git.createRef;
  state.github.rest.git.createRef = async request => {
    state.tags.push({ name: 'v1.0.1', sha: state.shas[0] });
    state.github.rest.git.createRef = create;
    throw Object.assign(new Error('Exists'), { status: 422 });
  };
  await autoTag(state);
  assert.deepEqual(state.created, [{ name: 'v1.0.2', sha: state.shas.at(-1) }]);
});

test('late CI for an older merge never tags a regression', async testContext => {
  const state = fixture(testContext, ['base', 'bot-first', 'bot-last']);
  state.tags.push({ name: 'v1.0.1', sha: state.shas.at(-1) });
  state.currentRun.head_sha = state.shas[1];
  await autoTag(state);
  assert.equal(state.created.length, 0);
  assert.equal(state.dispatches.length, 0);
  assert.match(state.messages.at(-1), /already covered/);
});

test('failed or unrelated CI and a missing gate cannot allocate tags', async testContext => {
  const state = fixture(testContext);
  state.currentRun.conclusion = 'failure';
  await assert.rejects(autoTag(state), /successful main push CI/);
  state.currentRun.conclusion = 'success';
  const paginate = state.github.paginate;
  state.github.paginate = async (method, args) => method === state.github.rest.actions.listJobsForWorkflowRun ? [] : paginate(method, args);
  await assert.rejects(autoTag(state), /CI Gate/);
  assert.equal(state.created.length, 0);
});

test('missing or ambiguous associated PRs fail closed', async testContext => {
  const state = fixture(testContext);
  const paginate = state.github.paginate;
  state.github.paginate = async (method, args) => method === state.github.rest.repos.listPullRequestsAssociatedWithCommit ? [] : paginate(method, args);
  await autoTag(state);
  state.github.paginate = async (method, args) => {
    const result = await paginate(method, args);
    return method === state.github.rest.repos.listPullRequestsAssociatedWithCommit ? [...result, ...result] : result;
  };
  await autoTag(state);
  assert.equal(state.created.length, 0);
});

test('a stable baseline on unrelated history pauses instead of tagging', async testContext => {
  const state = fixture(testContext);
  const unrelated = state.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit-tree', 'HEAD^{tree}', '-m', 'unrelated');
  state.tags.push({ name: 'v3.0.0', sha: unrelated });
  await autoTag(state);
  assert.equal(state.created.length, 0);
  assert.match(state.messages.at(-1), /latest stable tag is not an ancestor/);
});

test('manual release tags resolve to main commits and detect moved tags', async testContext => {
  const state = fixture(testContext);
  const oldTag = process.env.RELEASE_TAG;
  process.env.RELEASE_TAG = 'v2.0.0';
  testContext.after(() => { if (oldTag === undefined) delete process.env.RELEASE_TAG; else process.env.RELEASE_TAG = oldTag; });
  let target = state.shas.at(-1);
  state.github.rest.git.getRef = async () => ({ data: { object: { type: 'commit', sha: target } } });
  const outputs = {};
  state.core.setOutput = (name, value) => { outputs[name] = value; };
  state.context.eventName = 'workflow_dispatch';
  await resolveRelease(state);
  assert.deepEqual(outputs, { tag: 'v2.0.0', version: '2.0.0', sha: target });
  state.context.eventName = 'push';
  state.github.rest.git.getRef = async () => ({ data: { object: { type: 'tag', sha: 'annotated-object' } } });
  state.github.rest.git.getTag = async () => ({ data: { object: { type: 'commit', sha: target } } });
  state.context.payload.after = target;
  await resolveRelease(state);
  state.context.payload.after = 'annotated-object';
  await resolveRelease(state);
  state.context.payload.after = 'old-sha';
  await assert.rejects(resolveRelease(state), /moved/);
  state.context.eventName = 'workflow_dispatch';
  target = state.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit-tree', 'HEAD^{tree}', '-m', 'unrelated');
  await assert.rejects(resolveRelease(state), /must be on main/);
  process.env.RELEASE_TAG = 'v2.0.0-rc.1';
  await assert.rejects(resolveRelease(state), /stable/);
});

test('image provenance and platform mismatches never permit overwrite', () => {
  const image = {
    os: 'linux', architecture: 'amd64', labels: {
      'org.opencontainers.image.version': '1.0.0', 'org.opencontainers.image.revision': sha,
      'org.opencontainers.image.source': 'https://github.com/owner/podroute',
    },
  };
  const verify = candidate => verifyImage(candidate, '1.0.0', sha, 'https://github.com/owner/podroute');
  assert.doesNotThrow(() => verify(image));
  for (const patch of [{ architecture: 'arm64' }, { os: 'windows' }, { labels: {} }]) {
    assert.throws(() => verify({ ...image, ...patch }), /refusing to overwrite/);
  }
});

test('release queues do not cancel pending versions and CI gate requires all suites', () => {
  for (const file of ['auto-tag.yml', 'release.yml']) {
    const workflow = readFileSync(join(__dirname, '../workflows', file), 'utf8');
    assert.match(workflow, /^concurrency:\n  group: .+\n  queue: max\n/m);
    assert.doesNotMatch(workflow, /cancel-in-progress: true/);
  }
  const ci = readFileSync(join(__dirname, '../workflows/ci.yml'), 'utf8');
  assert.match(ci, /needs: \[unit, containers, automation\]/);
  assert.match(ci, /all\(\.\[\]; \.result == "success"\)/);
  for (const result of ['success', 'failure', 'skipped', 'cancelled']) {
    const gate = execFileSync('jq', ['-r', 'all(.[]; .result == "success")'], {
      input: JSON.stringify({ unit: { result: 'success' }, containers: { result }, automation: { result: 'success' } }),
      encoding: 'utf8',
    }).trim();
    assert.equal(gate, result === 'success' ? 'true' : 'false');
  }
});

function publicationFixture(testContext) {
  const saved = { ...process.env };
  Object.assign(process.env, { RELEASE_TAG: 'v1.0.0', RELEASE_VERSION: '1.0.0', RELEASE_SHA: 'a'.repeat(40), GH_TOKEN: 'synthetic-token' });
  testContext.after(() => {
    for (const name of ['RELEASE_TAG', 'RELEASE_VERSION', 'RELEASE_SHA', 'GH_TOKEN']) {
      if (saved[name] === undefined) delete process.env[name]; else process.env[name] = saved[name];
    }
  });
  const image = {
    os: 'linux', architecture: 'amd64', digest: `sha256:${'b'.repeat(64)}`, labels: {
      'org.opencontainers.image.version': '1.0.0',
      'org.opencontainers.image.revision': process.env.RELEASE_SHA,
      'org.opencontainers.image.source': 'https://github.com/owner/podroute',
    },
  };
  const remote = new Map();
  const pushes = [];
  const releases = [];
  const state = {
    image, remote, pushes, releases,
    context: { repo: { owner: 'owner', repo: 'podroute' }, serverUrl: 'https://github.com', actor: 'renovate[bot]' },
    core: { summary: { addRaw: () => ({ write: async () => {} }) } },
    inspect: async name => remote.get(name) || null,
    localImage: () => ({ Os: image.os, Architecture: image.architecture, Config: { Labels: image.labels } }),
    docker: (command, ...args) => {
      if (command === 'push') {
        pushes.push(args[0]);
        remote.set(args[0].slice('ghcr.io/'.length).split(':')[0], image);
      } else assert.equal(command, 'tag');
    },
    github: { rest: {
      git: { getRef: async () => ({ data: { object: { type: 'commit', sha: process.env.RELEASE_SHA } } }) },
      repos: {
        getReleaseByTag: async () => {
          if (!releases.length) throw Object.assign(new Error('Missing'), { status: 404 });
          return { data: releases[0] };
        },
        generateReleaseNotes: async () => ({ data: { body: 'Generated notes' } }),
        createRelease: async release => {
          assert.equal(remote.size, 2);
          releases.push(release);
        },
      },
    } },
  };
  return state;
}

test('publication pushes the tested pair once and reruns verify both digests', async testContext => {
  const state = publicationFixture(testContext);
  await publish(state);
  assert.deepEqual(state.pushes, ['ghcr.io/owner/podroute-controller:1.0.0', 'ghcr.io/owner/podroute-gateway:1.0.0']);
  assert.equal(state.releases.length, 1);
  assert.match(state.releases[0].body, /Generated notes/);
  assert.match(state.releases[0].body, /podroute-controller@sha256:/);
  assert.match(state.releases[0].body, /podroute-gateway@sha256:/);
  await publish(state);
  assert.equal(state.pushes.length, 2);
  assert.equal(state.releases.length, 1);
});

test('partial publication retries the same version without replacing the first image', async testContext => {
  const state = publicationFixture(testContext);
  const docker = state.docker;
  state.docker = (command, ...args) => {
    if (command === 'push' && args[0].includes('gateway')) throw new Error('Synthetic push failure');
    docker(command, ...args);
  };
  await assert.rejects(publish(state), /Synthetic push failure/);
  assert.equal(state.releases.length, 0);
  assert.equal(state.remote.size, 1);
  state.docker = docker;
  await publish(state);
  assert.equal(state.pushes.length, 2);
  assert.equal(state.releases.length, 1);
  assert.equal(state.releases[0].tag_name, 'v1.0.0');
});

test('conflicting existing images, moved tags and registry errors never cause pushes', async testContext => {
  const state = publicationFixture(testContext);
  state.remote.set('owner/podroute-controller', { ...state.image, architecture: 'arm64' });
  await assert.rejects(publish(state), /refusing to overwrite/);
  state.remote.clear();
  state.inspect = async () => { throw new Error('Registry authorization failed'); };
  await assert.rejects(publish(state), /authorization failed/);
  state.github.rest.git.getRef = async () => ({ data: { object: { type: 'commit', sha: 'c'.repeat(40) } } });
  await assert.rejects(publish(state), /tag moved/);
  assert.equal(state.pushes.length, 0);
  assert.equal(state.releases.length, 0);
});

test('registry inspection distinguishes a missing tag from authorization and network failures', async testContext => {
  const originalFetch = global.fetch;
  testContext.after(() => { global.fetch = originalFetch; });
  const responses = [];
  global.fetch = async () => {
    const response = responses.shift();
    if (response instanceof Error) throw response;
    assert.ok(response, 'Unexpected registry request');
    return response;
  };
  const authorization = () => new Response(JSON.stringify({ token: 'synthetic-token' }));
  responses.push(authorization(), new Response('', { status: 404 }));
  assert.equal(await registryImage('owner/podroute-controller', '1.0.0', 'actor', 'synthetic-secret'), null);
  responses.push(authorization(), new Response('', { status: 403 }));
  await assert.rejects(registryImage('owner/podroute-controller', '1.0.0', 'actor', 'synthetic-secret'), /lookup failed \(403\)/);
  responses.push(new Response('', { status: 401 }));
  await assert.rejects(registryImage('owner/podroute-controller', '1.0.0', 'actor', 'synthetic-secret'), /authentication failed \(401\)/);
  responses.push(authorization(), new Error('Synthetic network error'));
  await assert.rejects(registryImage('owner/podroute-controller', '1.0.0', 'actor', 'synthetic-secret'), /network error/);
  const digest = `sha256:${'a'.repeat(64)}`;
  responses.push(
    authorization(),
    new Response(JSON.stringify({ config: { digest } }), { headers: { 'docker-content-digest': digest } }),
    new Response(JSON.stringify({ os: 'linux', architecture: 'amd64', config: { Labels: { version: '1.0.0' } } })),
  );
  const remote = await registryImage('owner/podroute-controller', '1.0.0', 'actor', 'synthetic-secret');
  assert.equal(remote.digest, digest);
  assert.equal(remote.architecture, 'amd64');
});