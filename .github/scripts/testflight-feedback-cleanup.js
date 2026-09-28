// Purge a closed TestFlight-feedback issue's screenshots from the assets branch.
//
// Triggered when an issue is closed. Reads the `tf-feedback-id` marker from the
// issue body, then rebuilds the `testflight-feedback-assets` branch as a single
// orphan commit containing every other issue's screenshots but not this one's.
// Rebuilding to one root commit (no parents) means the branch history never
// grows — the removed blobs become unreferenced and GitHub garbage-collects
// them, so the repo doesn't balloon.
//
// Run from a workflow via actions/github-script:
//   await require('./.github/scripts/testflight-feedback-cleanup.js')({ github, context, core })

const ASSETS_BRANCH = 'testflight-feedback-assets';
const ASSETS_README = 'Auto-managed TestFlight feedback screenshots. Do not edit by hand.\n';

module.exports = async ({ github, context, core }) => {
  // Pin the REST API version on every request (silences Octokit's Sunset
  // deprecation warning — 2022-11-28 is itself now deprecated in favour of
  // 2026-03-10, see https://docs.github.com/rest/about-the-rest-api/api-versions).
  github.hook.before('request', (options) => {
    options.headers['x-github-api-version'] = '2026-03-10';
  });

  const { owner, repo } = context.repo;
  const issue = context.payload.issue;

  const m = (issue.body || '').match(/<!-- tf-feedback-id: ([^\s]+) -->/);
  if (!m) {
    core.info(`Issue #${issue.number} has no tf-feedback-id marker — nothing to clean.`);
    return;
  }
  const id = m[1];
  const prefix = `testflight-feedback/${id}/`;

  // Resolve the assets branch tip → tree.
  let ref;
  try {
    ref = await github.rest.git.getRef({ owner, repo, ref: `heads/${ASSETS_BRANCH}` });
  } catch (err) {
    if (err.status === 404) {
      core.info(`Assets branch ${ASSETS_BRANCH} does not exist — nothing to clean.`);
      return;
    }
    throw err;
  }
  const commit = await github.rest.git.getCommit({ owner, repo, commit_sha: ref.data.object.sha });
  const tree = await github.rest.git.getTree({
    owner, repo, tree_sha: commit.data.tree.sha, recursive: 'true',
  });

  const blobs = tree.data.tree.filter((t) => t.type === 'blob');
  const removed = blobs.filter((t) => t.path.startsWith(prefix));
  if (removed.length === 0) {
    core.info(`No screenshots found for feedback item ${id} (issue #${issue.number}).`);
    return;
  }
  if (tree.data.truncated) {
    core.warning('Assets tree was truncated by the API; skipping squash to avoid data loss.');
    return;
  }

  // Keep every other blob; reuse their existing blob shas (no new storage).
  let keep = blobs
    .filter((t) => !t.path.startsWith(prefix))
    .map((t) => ({ path: t.path, mode: t.mode, type: 'blob', sha: t.sha }));

  // A tree can't be empty — fall back to the README placeholder.
  if (keep.length === 0) {
    const blob = await github.rest.git.createBlob({
      owner, repo, content: Buffer.from(ASSETS_README).toString('base64'), encoding: 'base64',
    });
    keep = [{ path: 'README.md', mode: '100644', type: 'blob', sha: blob.data.sha }];
  }

  const newTree = await github.rest.git.createTree({ owner, repo, tree: keep });
  const newCommit = await github.rest.git.createCommit({
    owner,
    repo,
    message: `chore(feedback): purge screenshots for closed issue #${issue.number} (${id})`,
    tree: newTree.data.sha,
    parents: [], // orphan → single-commit history, removed blobs left unreferenced
  });
  await github.rest.git.updateRef({
    owner, repo, ref: `heads/${ASSETS_BRANCH}`, sha: newCommit.data.sha, force: true,
  });

  core.notice(
    `Purged ${removed.length} screenshot(s) for feedback ${id} (issue #${issue.number}); ` +
    `${ASSETS_BRANCH} squashed to a single commit.`
  );
};
