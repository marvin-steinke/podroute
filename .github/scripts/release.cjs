const { execFileSync } = require('node:child_process');

const stableVersion = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const bot = 'renovate[bot]';

function parseVersion(tag) {
  const match = stableVersion.exec(tag);
  return match ? match.slice(1).map(BigInt) : null;
}

function compareVersions(left, right) {
  const leftParts = parseVersion(left);
  const rightParts = parseVersion(right);
  if (!leftParts || !rightParts) throw new Error('Expected stable vMAJOR.MINOR.PATCH tags');
  for (const index of [0, 1, 2]) {
    if (leftParts[index] !== rightParts[index]) return leftParts[index] > rightParts[index] ? 1 : -1;
  }
  return 0;
}

function nextVersion(tags) {
  const latest = tags.filter(parseVersion).sort(compareVersions).at(-1);
  if (!latest) return 'v1.0.0';
  const [major, minor, patch] = parseVersion(latest);
  return `v${major}.${minor}.${patch + 1n}`;
}

function successfulMainCI(run, repository) {
  return run.event === 'push' && run.status === 'completed' && run.conclusion === 'success' &&
    run.head_branch === 'main' && run.head_repository?.full_name === repository &&
    run.path === '.github/workflows/ci.yml';
}

function renovateMerge(pull, commits, sha, repository) {
  return pull.merged === true && pull.base?.ref === 'main' &&
    pull.base?.repo?.full_name === repository && pull.head?.repo?.full_name === repository &&
    pull.user?.login === bot && pull.merged_by?.login === bot && pull.merge_commit_sha === sha &&
    commits.length > 0 && commits.length === pull.commits &&
    commits.every(commit => commit.author?.login === bot);
}

async function peelTag(github, repo, object) {
  const seen = new Set();
  while (object.type === 'tag') {
    if (seen.has(object.sha)) throw new Error('Tag cycle');
    seen.add(object.sha);
    const response = await github.rest.git.getTag({ ...repo, tag_sha: object.sha });
    object = response.data.object;
  }
  if (object.type !== 'commit') throw new Error('Release tag must point to a commit');
  return object.sha;
}

async function listStableTags(github, repo) {
  const refs = await github.paginate(github.rest.git.listMatchingRefs, { ...repo, ref: 'tags/v', per_page: 100 });
  const tags = [];
  for (const ref of refs) {
    const name = ref.ref.slice('refs/tags/'.length);
    if (parseVersion(name)) tags.push({ name, sha: await peelTag(github, repo, ref.object) });
  }
  return tags.sort((left, right) => compareVersions(left.name, right.name));
}

async function eligibleCommit(github, repo, sha) {
  const associated = await github.paginate(github.rest.repos.listPullRequestsAssociatedWithCommit, {
    ...repo, commit_sha: sha, per_page: 100,
  });
  const matching = associated.filter(pull => pull.merge_commit_sha === sha && pull.base.ref === 'main');
  if (matching.length !== 1) return false;
  const { data: pull } = await github.rest.pulls.get({ ...repo, pull_number: matching[0].number });
  const commits = await github.paginate(github.rest.pulls.listCommits, {
    ...repo, pull_number: pull.number, per_page: 100,
  });
  return renovateMerge(pull, commits, sha, `${repo.owner}/${repo.repo}`);
}

async function botOnlyHistory(shas, eligible) {
  for (const sha of shas) {
    if (!await eligible(sha)) return sha;
  }
  return null;
}

function git(...args) {
  return execFileSync('git', args, { encoding: 'utf8' }).trim();
}

function isAncestor(ancestor, descendant) {
  try {
    git('merge-base', '--is-ancestor', ancestor, descendant);
    return true;
  } catch (error) {
    if (error.status === 1) return false;
    throw error;
  }
}

async function autoTag({ github, context, core }) {
  const repo = context.repo;
  const repository = `${repo.owner}/${repo.repo}`;
  const { data: run } = await github.rest.actions.getWorkflowRun({
    ...repo, run_id: context.payload.workflow_run.id,
  });
  if (!successfulMainCI(run, repository)) throw new Error('Not successful main push CI');
  const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
    ...repo, run_id: run.id, filter: 'latest', per_page: 100,
  });
  if (!jobs.some(job => job.name === 'CI Gate' && job.conclusion === 'success')) {
    throw new Error('CI Gate did not succeed');
  }
  const sha = run.head_sha;
  const report = async message => {
    core.info(message);
    await core.summary.addRaw(message).write();
  };
  if (!isAncestor(sha, 'origin/main')) throw new Error('Candidate is not on main');
  if (!await eligibleCommit(github, repo, sha)) {
    await report('No automatic release: this commit is not a Renovate-only bot merge.');
    return;
  }
  for (let attempt = 0; attempt < 3; attempt++) {
    const tags = await listStableTags(github, repo);
    const existing = tags.filter(tag => tag.sha === sha).at(-1);
    let tag = existing?.name;
    if (!tag) {
      const latest = tags.at(-1);
      if (latest) {
        if (isAncestor(sha, latest.sha)) {
          await report(`No automatic release: ${sha} is already covered by ${latest.name}.`);
          return;
        }
        if (!isAncestor(latest.sha, sha)) {
          await report('Automatic release paused: latest stable tag is not an ancestor. Create a manual release tag.');
          return;
        }
        const history = git('rev-list', '--first-parent', '--reverse', `${latest.sha}..${sha}`).split('\n').filter(Boolean);
        const firstParent = git('rev-list', '--first-parent', sha).split('\n');
        if (!firstParent.includes(latest.sha)) throw new Error('Baseline is not on main first-parent history');
        const blocked = await botOnlyHistory(history, commit => eligibleCommit(github, repo, commit));
        if (blocked) {
          await report(`Automatic release paused: unreleased human or unattributed change ${blocked}. Create a manual release tag first.`);
          return;
        }
      }
      tag = nextVersion(tags.map(entry => entry.name));
      try {
        await github.rest.git.createRef({ ...repo, ref: `refs/tags/${tag}`, sha });
      } catch (error) {
        if (error.status !== 422) throw error;
        if (attempt === 2) throw error;
        continue;
      }
    }
    await github.rest.actions.createWorkflowDispatch({
      ...repo, workflow_id: 'release.yml', ref: 'main', inputs: { tag },
    });
    await report(`Release requested for ${tag} at ${sha}. Both images share this version.`);
    return;
  }
}

async function resolveRelease({ github, context, core }) {
  const tag = process.env.RELEASE_TAG;
  if (!parseVersion(tag)) throw new Error('Expected stable vMAJOR.MINOR.PATCH tag');
  const { data: ref } = await github.rest.git.getRef({ ...context.repo, ref: `tags/${tag}` });
  const sha = await peelTag(github, context.repo, ref.object);
  if (!isAncestor(sha, 'origin/main')) throw new Error('Release target must be on main');
  if (context.eventName === 'push' && context.payload.after !== ref.object.sha && context.payload.after !== sha) {
    throw new Error('Tag moved since the push event');
  }
  core.setOutput('tag', tag);
  core.setOutput('version', tag.slice(1));
  core.setOutput('sha', sha);
}

async function registryImage(image, version, actor, token) {
  const credentials = Buffer.from(`${actor}:${token}`).toString('base64');
  const authorization = await fetch(`https://ghcr.io/token?service=ghcr.io&scope=repository:${image}:pull,push`, {
    headers: { Authorization: `Basic ${credentials}` },
  });
  if (!authorization.ok) throw new Error(`Registry authentication failed (${authorization.status})`);
  const access = await authorization.json();
  if (!access.token) throw new Error('Missing registry access token');
  const headers = {
    Authorization: `Bearer ${access.token}`,
    Accept: 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json',
  };
  const response = await fetch(`https://ghcr.io/v2/${image}/manifests/${version}`, { headers });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Registry manifest lookup failed (${response.status})`);
  const digest = response.headers.get('docker-content-digest');
  if (!/^sha256:[a-f0-9]{64}$/.test(digest)) throw new Error('Missing immutable image digest');
  const manifest = await response.json();
  if (!/^sha256:[a-f0-9]{64}$/.test(manifest.config?.digest)) throw new Error('Expected a single-platform image');
  const configResponse = await fetch(`https://ghcr.io/v2/${image}/blobs/${manifest.config.digest}`, { headers });
  if (!configResponse.ok) throw new Error(`Registry config lookup failed (${configResponse.status})`);
  const config = await configResponse.json();
  return { digest, labels: config.config?.Labels, os: config.os, architecture: config.architecture };
}

function verifyImage(image, version, sha, source) {
  if (image.os !== 'linux' || image.architecture !== 'amd64' ||
      image.labels?.['org.opencontainers.image.version'] !== version ||
      image.labels?.['org.opencontainers.image.revision'] !== sha ||
      image.labels?.['org.opencontainers.image.source'] !== source) {
    throw new Error('Existing image does not match release version, source, revision and linux/amd64; refusing to overwrite');
  }
}

async function publish({
  github, context, core, inspect = registryImage,
  docker = (...args) => execFileSync('docker', args, { stdio: 'inherit' }),
  localImage = component => JSON.parse(execFileSync('docker', ['image', 'inspect', `podroute-${component}:local`], { encoding: 'utf8' }))[0],
}) {
  const tag = process.env.RELEASE_TAG;
  const version = process.env.RELEASE_VERSION;
  const sha = process.env.RELEASE_SHA;
  if (!parseVersion(tag) || tag.slice(1) !== version || !/^[a-f0-9]{40}$/.test(sha)) {
    throw new Error('Invalid release inputs');
  }
  const source = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}`;
  const assertTag = async () => {
    const { data: ref } = await github.rest.git.getRef({ ...context.repo, ref: `tags/${tag}` });
    if (await peelTag(github, context.repo, ref.object) !== sha) throw new Error('Release tag moved; refusing publication');
  };
  await assertTag();
  let release;
  try {
    release = (await github.rest.repos.getReleaseByTag({ ...context.repo, tag })).data;
  } catch (error) {
    if (error.status !== 404) throw error;
  }
  if (release?.draft || release?.prerelease) throw new Error('Conflicting draft or prerelease exists');
  const images = [];
  for (const component of ['controller', 'gateway']) {
    const image = `${context.repo.owner.toLowerCase()}/podroute-${component}`;
    const reference = `ghcr.io/${image}:${version}`;
    let remote = await inspect(image, version, context.actor, process.env.GH_TOKEN);
    if (!remote && release) throw new Error(`Published release is missing ${reference}`);
    if (!remote) {
      const local = localImage(component);
      verifyImage({ os: local.Os, architecture: local.Architecture, labels: local.Config.Labels }, version, sha, source);
      await assertTag();
      docker('tag', `podroute-${component}:local`, reference);
      docker('push', reference);
      remote = await inspect(image, version, context.actor, process.env.GH_TOKEN);
      if (!remote) throw new Error(`Published image is missing: ${reference}`);
    }
    verifyImage(remote, version, sha, source);
    images.push(`${reference} (${`ghcr.io/${image}@${remote.digest}`})`);
  }
  await assertTag();
  if (!release) {
    const { data: notes } = await github.rest.repos.generateReleaseNotes({ ...context.repo, tag_name: tag, target_commitish: sha });
    await github.rest.repos.createRelease({
      ...context.repo, tag_name: tag, target_commitish: sha, name: tag,
      body: `${notes.body}\n\nCommit: ${sha}\n\n${images.map(image => `- ${image}`).join('\n')}`,
      make_latest: 'legacy',
    });
  }
  await core.summary.addRaw(`${tag} at ${sha}\n\n${images.join('\n\n')}`).write();
}

module.exports = {
  parseVersion, compareVersions, nextVersion, successfulMainCI, renovateMerge,
  peelTag, listStableTags, eligibleCommit, botOnlyHistory, autoTag, resolveRelease,
  registryImage, verifyImage, publish,
};