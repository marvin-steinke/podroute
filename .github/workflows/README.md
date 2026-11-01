# CI And Releases

PodRoute uses stable Git tags as its only version source. The controller and
gateway always receive the same image version. Dependency versions may change
by any amount, but automatic PodRoute versions increase only the patch number.

## Workflow Responsibilities

| Workflow | Trigger | Behavior |
| --- | --- | --- |
| [CI](ci.yml) | Every PR to any branch; every push to `main` | Runs Go race tests, shell tests, lint, controller build, both runtime image builds, runtime smoke tests, isolated networking tests, release-policy tests, actionlint and Renovate config validation. |
| [Renovate](renovate.yml) | Weekly on Sunday at 00:00 UTC; manual dispatch | Runs self-hosted Renovate against this repository using its configured token. |
| [Automatic Patch Tag](auto-tag.yml) | Completion of successful push CI on `main` | Validates the run and bot merge through GitHub APIs, checks unreleased history, creates an immutable patch tag and dispatches Release. PR CI never grants this authority. |
| [Release](release.yml) | Pushed `v*` tag or dispatch with an existing stable tag | Validates the tag, checks out its exact commit, reruns tests and builds, publishes both tested images, then creates a GitHub Release with commit and image digests. |

`CI Gate` runs even when a dependency job fails. It succeeds only when `Unit And
Lint`, `Containers` and `Automation` all succeed; skipped or cancelled jobs fail
the gate. There are no PR path exclusions. PR tokens are read-only and have no
registry credentials. Privileged networking tests run only on ephemeral hosted
runners, not a persistent trusted server.

CI and release actions are pinned by commit; the Renovate workflow uses version
tags. Actionlint 1.7.12 does not recognize GitHub's
documented `concurrency.queue` option, so validation excludes only that diagnostic;
the release-helper tests separately require `queue: max`. Other actionlint errors
still fail CI. Allocator events and duplicate publications queue rather than
cancel pending work. GitHub's queue limit is 100 pending runs; overflow requires
rerunning the affected workflow.

## Renovate Automerge

[Renovate configuration](../renovate.json) enables squash automerge for all
dependency update types on `main`, including major updates and action pins.
Renovate must see passing checks and rebase behind branches before merging.
Major updates do not need Dependency Dashboard approval. It uses its own merge
API (`platformAutomerge: false`), so merging may wait for Renovate's next run;
GitHub's separate "Allow auto-merge" setting is not required.

Automatic releases require all of these conditions:

- The exact merge commit passed push CI on `main`, including `CI Gate`.
- The associated PR author and the account that merged it are both `renovate[bot]`.
- Every source PR commit resolves through GitHub to the same bot author.
- The PR belongs to this repository and targets `main`; identity or attribution
  missing from the API fails closed.
- Every unreleased first-parent change since the highest stable tag is also an
  eligible bot-only merge.

A human merging a Renovate PR does not create an automatic tag. A human commit,
manual merge, or unattributed change pauses subsequent automatic releases, even
when a later bot merge passes CI. Create a manual stable tag covering those
changes to establish a new baseline. A passing test suite is the release policy,
not proof that a dependency update preserves every feature; identity checks are
not cryptographic proof that a human never influenced the code.

## Versions And Images

Only `vMAJOR.MINOR.PATCH` tags are accepted, with numeric components and no leading
zeroes, prerelease suffix or build metadata. Comparison is numeric, not lexical.
The highest stable version supplies the baseline: `v1.0.9` becomes `v1.0.10`,
`v1.1.0` becomes `v1.1.1`, and a manual `v2.0.0` makes the next patch `v2.0.1`.
Tags ahead of or unrelated to a candidate never cause an older tree to be
published under a newer version.

With no stable tags, the first eligible bot merge bootstraps **v1.0.0**, including
the preexisting code as its initial baseline. This is the one exception to the
unreleased-human-history rule. Create an initial manual `v1.0.0` first to choose
that baseline yourself instead.

For `v1.2.3`, publication produces:

```text
ghcr.io/<owner>/podroute-controller:1.2.3
ghcr.io/<owner>/podroute-gateway:1.2.3
```

The owner namespace is lowercased. Both images are `linux/amd64`, with OCI source,
revision and version labels. No `latest`, floating major/minor aliases, ARM
images, separate component versions or standalone binary assets are published.
The release notes include immutable `@sha256:...` references for both images.

## Required Repository Setup

Workflow files do not configure server-side protection. An administrator must:

1. Enable GitHub Actions and allow the actions used by the workflows. Configure
   the `RENOVATE_TOKEN` repository secret with credentials that can manage
   dependency updates and pull requests, merge PRs, and update workflow files.
   Automatic releases additionally require the Renovate identity described above.
2. Enable squash merges. Protect `main`: require PRs and the GitHub Actions check
   **CI Gate**, require branches to be up to date before merging, and prohibit
   force pushes/deletion. Let the first CI run register the check if necessary.
   Do not grant the bot a bypass of required tests. Existing review/approval
   requirements must be deliberately reconciled with unattended merges, not
   silently removed; they can otherwise prevent Renovate from merging.
3. Allow the scoped `GITHUB_TOKEN` permissions declared by the workflows:
   allocator `contents: write`, `pull-requests: read`, `actions: write`;
   publisher `contents: write`, `packages: write`. PR CI needs only contents read.
   Organization policies may restrict these permissions.
4. Protect stable tags against updates/deletion, while permitting authorized
   maintainers and this workflow to create new tags. Do not blanket-bypass PR
   protections to solve a tag-creation rule conflict.
5. Grant this repository Actions write access to any preexisting GHCR packages
   named `podroute-controller` and `podroute-gateway`. New packages use the OCI
   source label for repository linkage. Check package visibility explicitly:
   GHCR packages may initially be private even for public repositories.

GitHub suppresses follow-on tag-push workflows for tags
created with `GITHUB_TOKEN`. Therefore the allocator explicitly invokes
`workflow_dispatch` on `main`, passing the tag it just created. Manual tags pushed
using a maintainer's credentials trigger Release directly.

## Manual Versions

Choose a trusted `main` commit containing this automation. Lightweight and
annotated tags are both supported; tag names and source commits never change.
For a minor version:

```sh
git fetch origin main --tags
git tag -a v1.1.0 origin/main -m 'Release v1.1.0'
git push origin v1.1.0
```

For a major version use `v2.0.0` instead. To bootstrap manually use `v1.0.0`.
The release workflow requires the tagged commit to be reachable from `main`
and reruns the tests at that exact commit before authenticating to GHCR.

## Failure And Retry

Rerun a failed Automatic Patch Tag workflow if tag creation or dispatch failed.
It reuses a tag already pointing at that commit rather than incrementing again.
An older CI completion already covered by a later tag is skipped. Tag collisions
refresh the version state and retry without updating an existing ref.

For a failed release, rerun it in Actions or dispatch the existing tag:

```sh
gh workflow run release.yml --ref main -f tag=v1.2.3
```

Do not delete, move or recreate tags and do not allocate another patch just to
retry. Each release run rebuilds and retests locally; it reuses already-published
images only after checking their version, source, revision, platform and digest.
Conflicting images or authentication/network errors fail instead of overwriting.
Published releases are verified and otherwise left unchanged on reruns.

Two image repositories cannot be updated atomically: a first push can succeed
while the second fails. The GitHub Release is created only after both images
are present and verified. Retry the same tag to complete the pair. Avoid external
writers to these version tags; digest references remain the deployment identity.
Package/tag permission failures need an administrator to correct access first.

## Coverage Boundary

See [the test guide](../../tests/README.md) for assertions and local commands.
The networking fixture uses synthetic endpoints and a local WireGuard peer.
It does not test a real Kubernetes installation, an external VPN provider or
production performance. No deployment occurs as part of release publication.