// TestFlight beta feedback → GitHub issues.
//
// Polls the App Store Connect "beta feedback screenshot submissions" endpoint,
// turns each new submission into a triaged + refined GitHub issue (device
// context pulled through), then deletes the submission from App Store Connect so
// it isn't processed again.
//
// The repo is public, so nothing identifying a tester goes into an issue, and
// screenshots (which show testers' connections) are only published when
// PUBLISH_SCREENSHOTS is set. Otherwise they stay in App Store Connect, and the
// submission is kept there until its issue is closed.
//
// Run from a workflow via actions/github-script:
//   await require('./.github/scripts/testflight-feedback.js')({ github, context, core })
//
// Needs (env): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT (.p8 contents),
// OPENROUTER_API_KEY. Optional: ASC_APP_ID or ASC_BUNDLE_ID, OPENROUTER_MODEL,
// FEEDBACK_LIMIT, PUBLISH_SCREENSHOTS, DRY_RUN.
//
// Only confirmed App Store Connect 4.0 endpoints are used:
//   GET    /v1/apps/{id}/betaFeedbackScreenshotSubmissions   (list, full objects)
//   DELETE /v1/betaFeedbackScreenshotSubmissions/{id}        (204 on success)

const shared = require('./testflight-shared');

const FEEDBACK_LABEL = 'testflight-feedback';
const ID_KIND = 'feedback';
const ID_MARKER = (id) => shared.idMarker(ID_KIND, id);
const REFINED_MARKER = shared.REFINED_MARKER;
const MAX_TITLE_LENGTH = shared.MAX_TITLE_LENGTH;

// Attribute fields we want back for each submission (see the API reference).
const SUBMISSION_FIELDS = [
  'createdDate', 'comment', 'deviceModel', 'osVersion', 'locale',
  'timeZone', 'architecture', 'connectionType', 'batteryPercentage',
  'appPlatform', 'devicePlatform', 'deviceFamily', 'buildBundleId',
  'screenshots', 'build',
].join(',');

module.exports = async ({ github, context, core }) => {
  shared.pinApiVersion(github);

  const cfg = loadConfig(core);
  const { owner, repo } = context.repo;

  const token = shared.makeAscToken(cfg);
  const appId = cfg.appId || (await shared.resolveAppId(token, cfg.bundleId, core));
  core.info(`Polling App Store Connect feedback for app ${appId}…`);

  const submissions = await listSubmissions(token, appId, cfg.limit, core);
  core.info(`Found ${submissions.length} screenshot submission(s).`);
  if (submissions.length === 0) {
    return;
  }

  const existing = await shared.loadProcessedIssues({ github, owner, repo }, { label: FEEDBACK_LABEL, kind: ID_KIND });

  const summary = { created: 0, untriaged: 0, skipped: 0, deleted: 0, failed: 0 };

  for (const sub of submissions) {
    const id = sub.id;
    try {
      if (existing.has(id)) {
        summary.skipped++;
        if (cfg.publishScreenshots || existing.get(id).state === 'closed') {
          core.info(`#${id}: issue already exists — deleting submission only.`);
          if (await deleteSubmission(token, id, cfg, core)) summary.deleted++;
        } else {
          core.info(`#${id}: issue still open — keeping submission for its screenshots.`);
        }
        continue;
      }

      const detail = describeSubmission(sub, submissions.included);
      const shots = await downloadScreenshots(detail.screenshots, core);
      let hosted = [];
      if (cfg.publishScreenshots) {
        hosted = cfg.dryRun
          ? shots.map((s, i) => ({ name: s.name, url: `(dry-run, not uploaded ${i})` }))
          : await commitScreenshots({ github, owner, repo }, id, shots, core);
      }

      const triage = await triageFeedback(cfg, detail, shots, core);

      if (cfg.dryRun) {
        core.info(`#${id}: DRY_RUN — would create "${triage.titlePrefix}${triage.title}" (${triage.type}) with ${hosted.length} screenshot(s).`);
        summary.created++;
        continue;
      }

      const issue = await createIssue(
        { github, owner, repo },
        { id, detail, triage, hosted, keptShots: hosted.length ? 0 : shots.length, core }
      );
      summary.created++;
      if (triage.ok) {
        core.info(`#${id}: opened issue #${issue.number} — ${issue.html_url}`);
      } else {
        summary.untriaged++;
        core.warning(`#${id}: opened issue #${issue.number} without triage — ${issue.html_url}`);
      }

      // Only a triaged issue is safe to remove from App Store Connect. An
      // untriaged one is kept so a later run can re-triage it against the same
      // submission, and the issue is still open; deleting it would destroy the
      // only copy of the feedback before anyone has read it.
      if (triage.ok && (hosted.length || shots.length === 0)) {
        if (await deleteSubmission(token, id, cfg, core)) summary.deleted++;
      }
    } catch (err) {
      summary.failed++;
      core.warning(`#${id}: failed — ${err.message} (left in App Store Connect for retry)`);
    }
  }

  core.notice(
    `TestFlight feedback: created ${summary.created} (${summary.untriaged} untriaged), ` +
    `skipped ${summary.skipped}, deleted ${summary.deleted}, failed ${summary.failed}.`
  );
  // An untriaged issue is a real failure, not a lesser success: the run goes red
  // so somebody notices instead of a degraded issue quietly accumulating.
  if (summary.failed + summary.untriaged > 0) {
    core.setFailed(`${summary.failed + summary.untriaged} submission(s) failed or could not be triaged — see logs.`);
  }
};

// ---- config --------------------------------------------------------------

function loadConfig(core) {
  return {
    ...shared.loadAscConfig(),
    ...shared.loadOpenRouterConfig(),
    limit: Number.parseInt(process.env.FEEDBACK_LIMIT || '50', 10),
    publishScreenshots: shared.publishScreenshots(),
    dryRun: shared.isDryRun(),
  };
}

// ---- App Store Connect REST ----------------------------------------------

// These newer beta-feedback endpoints intermittently 500 on richer sparse
// fieldset / include combinations, so try progressively simpler queries and
// retry transient 5xx. The first query that works is used for pagination.
function submissionQueries() {
  const rich = new URLSearchParams({
    include: 'build',
    'fields[betaFeedbackScreenshotSubmissions]': SUBMISSION_FIELDS,
    'fields[builds]': 'version,preReleaseVersion',
    limit: '200',
  });
  const withInclude = new URLSearchParams({ include: 'build', limit: '200' });
  const plain = new URLSearchParams({ limit: '200' });
  return [rich.toString(), withInclude.toString(), plain.toString()];
}

async function listSubmissions(token, appId, limit, core) {
  const queries = submissionQueries();
  let lastErr;
  for (const [i, query] of queries.entries()) {
    try {
      const path = `/v1/apps/${appId}/betaFeedbackScreenshotSubmissions?${query}`;
      const data = await shared.fetchPaged(token, path, limit);
      if (i > 0) core.warning(`Used simplified feedback query #${i + 1} (richer query failed).`);
      const sliced = data.slice(0, limit);
      sliced.included = data.included;
      return sliced;
    } catch (err) {
      lastErr = err;
      core.info(`Feedback query #${i + 1} failed (${err.message.slice(0, 120)}) — trying simpler.`);
    }
  }
  throw new Error(`list submissions failed: ${lastErr?.message || 'unknown'}`);
}

async function deleteSubmission(token, id, cfg, core) {
  if (cfg.dryRun) {
    core.info(`#${id}: DRY_RUN — would delete submission.`);
    return false;
  }
  const res = await shared.asc(token, `/v1/betaFeedbackScreenshotSubmissions/${id}`, { method: 'DELETE' });
  if (res.status === 204 || res.status === 404) {
    core.info(`#${id}: submission deleted from App Store Connect.`);
    return true;
  }
  core.warning(`#${id}: delete returned ${res.status}: ${await res.text()}`);
  return false;
}

// ---- shaping -------------------------------------------------------------

function describeSubmission(sub, included = []) {
  const a = sub.attributes || {};
  const byRef = (ref) => included.find((i) => i.type === ref?.type && i.id === ref?.id);
  const build = byRef(sub.relationships?.build?.data);

  const buildAttr = build?.attributes || {};

  const screenshots = (a.screenshots || [])
    .map((s) => ({ name: s.fileName || s.name || 'screenshot.png', url: s.url }))
    .filter((s) => s.url);

  return {
    comment: (a.comment || '').trim(),
    createdDate: a.createdDate || '',
    deviceModel: a.deviceModel || '',
    osVersion: a.osVersion || '',
    locale: a.locale || '',
    timeZone: a.timeZone || '',
    batteryPercentage: a.batteryPercentage,
    connectionType: a.connectionType || '',
    appPlatform: a.appPlatform || '',
    buildBundleId: a.buildBundleId || '',
    buildVersion: buildAttr.version || '',
    buildPreRelease: buildAttr.preReleaseVersion?.version || '',
    screenshots,
  };
}

async function downloadScreenshots(screenshots, core) {
  const out = [];
  for (const [i, s] of screenshots.entries()) {
    try {
      const res = await fetch(s.url);
      if (!res.ok) {
        core.warning(`screenshot ${i} download failed (${res.status}) — skipping.`);
        continue;
      }
      const buf = Buffer.from(await res.arrayBuffer());
      out.push({ name: sanitiseName(s.name, i), data: buf });
    } catch (err) {
      core.warning(`screenshot ${i} download error: ${err.message}`);
    }
  }
  return out;
}

function sanitiseName(name, index) {
  const safe = (name || `screenshot-${index}.png`).replace(/[^a-zA-Z0-9._-]/g, '_');
  return /\.[a-z0-9]+$/i.test(safe) ? safe : `${safe}.png`;
}

// ---- screenshot hosting (commit to a dedicated orphan assets branch) -----

// main is protected (PRs + required checks), so screenshots are committed to a
// separate unprotected branch and referenced by their raw URL there. The branch
// is an orphan (no main history) so it only ever holds screenshots, and the
// cleanup workflow can squash it to a single commit when issues close.
const ASSETS_BRANCH = 'testflight-feedback-assets';
const ASSETS_README = 'Auto-managed TestFlight feedback screenshots. Do not edit by hand.\n';

async function ensureAssetsBranch({ github, owner, repo }, core) {
  const ref = `heads/${ASSETS_BRANCH}`;
  try {
    await github.rest.git.getRef({ owner, repo, ref });
    return;
  } catch (err) {
    if (err.status !== 404) throw err;
  }
  // Orphan root commit (no parents) with just a README, so the branch carries
  // none of main's files/history.
  const blob = await github.rest.git.createBlob({
    owner, repo, content: Buffer.from(ASSETS_README).toString('base64'), encoding: 'base64',
  });
  const tree = await github.rest.git.createTree({
    owner, repo, tree: [{ path: 'README.md', mode: '100644', type: 'blob', sha: blob.data.sha }],
  });
  const commit = await github.rest.git.createCommit({
    owner, repo, message: 'chore(feedback): initialise screenshots assets branch', tree: tree.data.sha, parents: [],
  });
  await github.rest.git.createRef({ owner, repo, ref: `refs/heads/${ASSETS_BRANCH}`, sha: commit.data.sha });
  core.info(`Created orphan assets branch ${ASSETS_BRANCH}.`);
}

async function commitScreenshots({ github, owner, repo }, id, shots, core) {
  if (!shots.length) return [];
  await ensureAssetsBranch({ github, owner, repo }, core);
  const hosted = [];
  for (const [i, shot] of shots.entries()) {
    const path = `testflight-feedback/${id}/${i}-${shot.name}`;
    await github.rest.repos.createOrUpdateFileContents({
      owner,
      repo,
      path,
      branch: ASSETS_BRANCH,
      message: `chore(feedback): screenshot for TestFlight submission ${id}`,
      content: shot.data.toString('base64'),
    });
    // Use the stable github.com/raw URL (not the contents API download_url,
    // whose token expires in minutes for private repos). GitHub serves this
    // with the viewer's session auth, so it renders for repo members and
    // stays private.
    const encoded = path.split('/').map(encodeURIComponent).join('/');
    const url = `https://github.com/${owner}/${repo}/raw/${ASSETS_BRANCH}/${encoded}`;
    hosted.push({ name: shot.name, url });
  }
  core.info(`#${id}: committed ${hosted.length} screenshot(s) to ${ASSETS_BRANCH}.`);
  return hosted;
}

// ---- triage (OpenRouter) -------------------------------------------------

async function triageFeedback(cfg, detail, shots, core) {
  const fs = require('fs');
  let systemPrompt = 'You triage TestFlight beta feedback for an iOS app into GitHub issues.';
  try {
    systemPrompt = fs.readFileSync('.github/prompts/testflight-triage.md', 'utf-8');
  } catch (_) { /* fall back to inline */ }

  const userPrompt = [
    "Triage and refine this TestFlight beta feedback into a ready-to-pick-up GitHub issue for Pear'd, an iOS app for sharing one-tap moments, photos and tallies with your favourite people.",
    '',
    `Tester comment:\n"""\n${detail.comment || '(no written comment — screenshot only)'}\n"""`,
    '',
    'Context:',
    `- Device: ${detail.deviceModel || 'unknown'} on iOS ${detail.osVersion || 'unknown'}`,
    `- App build: ${detail.buildPreRelease || detail.buildVersion || 'unknown'}`,
    `- Locale: ${detail.locale || 'unknown'}`,
    `- Screenshots attached: ${shots.length}`,
    '',
    shots.length ? 'The screenshot(s) are attached as images above. Examine them carefully — identify the visible screen, any error states, layout issues, or UI elements shown.' : '',
    '',
    'Return ONLY a JSON object with this shape:',
    `{"type":"bug|feature|other","title":"short imperative title without a prefix, at most ${MAX_TITLE_LENGTH} characters","brief":"Markdown brief with sections: Problem / motivation, Proposed solution, Acceptance criteria, Affected files / areas, Notes / assumptions"}`,
  ].join('\n');

  const parsed = await shared.triageJson(cfg, { systemPrompt, userPrompt, images: shots }, core);
  const ok = isUsableTriage(parsed);
  const type = ok && ['bug', 'feature', 'other'].includes(parsed.type) ? parsed.type : 'other';
  const title = shared.shortenTitle((ok && parsed.title) || fallbackTitle(detail));
  const brief = (ok && parsed.brief) || fallbackBrief(detail);
  const titlePrefix = type === 'bug' ? 'bug: ' : type === 'feature' ? 'feat: ' : 'feedback: ';
  const typeLabel = ok && type === 'bug' ? 'bug' : ok && type === 'feature' ? 'enhancement' : null;
  return { ok, type, title, brief, titlePrefix, typeLabel };
}

// A triage is only usable if the model actually returned a title and a brief. A
// partial object is treated as a failure: half a triage labelled `refined` is
// worse than an honest `needs-triage`.
function isUsableTriage(parsed) {
  return Boolean(parsed && typeof parsed.title === 'string' && parsed.title.trim()
    && typeof parsed.brief === 'string' && parsed.brief.trim());
}

function fallbackTitle(detail) {
  const c = detail.comment.replace(/\s+/g, ' ').trim();
  return c ? shared.shortenTitle(c) : `TestFlight feedback (${detail.deviceModel || 'device'})`;
}

function fallbackBrief(detail) {
  return [
    '### Problem / motivation',
    detail.comment || '_Screenshot-only feedback — no written comment._',
    '',
    '### Notes / assumptions',
    '_Automated triage was unavailable; please refine manually._',
  ].join('\n');
}

// ---- GitHub issue --------------------------------------------------------

async function ensureLabels(github, owner, repo) {
  await shared.ensureLabels(github, owner, repo, [
    { name: FEEDBACK_LABEL, color: '1D76DB', description: 'Imported from TestFlight beta feedback' },
    { name: 'refined', color: '0E8A16', description: 'Issue has been through refinement' },
    { name: 'needs-triage', color: 'FBCA04', description: 'Automated triage failed; will be retried' },
    { name: 'bug', color: 'D73A4A', description: "Something isn't working" },
    { name: 'enhancement', color: 'A2EEEF', description: 'New feature or request' },
  ]);
}

async function createIssue({ github, owner, repo }, { id, detail, triage, hosted, keptShots, core }) {
  await ensureLabels(github, owner, repo);

  const body = buildIssueBody({ id, detail, triage, hosted, keptShots });
  const labels = [FEEDBACK_LABEL];
  if (triage.ok) {
    labels.push('refined');
    if (triage.typeLabel) labels.push(triage.typeLabel);
  } else {
    // No `refined` and no type: neither is known to be true, and `refined` is
    // what tells the refinement bot (and a reader) the issue is already triaged.
    labels.push('needs-triage');
  }

  const { data: issue } = await github.rest.issues.create({
    owner,
    repo,
    title: `${triage.titlePrefix}${triage.title}`,
    body,
    labels,
  });

  // One tracking comment: the human-readable anchor plus the markers. The
  // refined brief itself lives in the issue body (not repeated here), and the
  // issue-refined marker stops the refinement bot from re-refining it. An
  // untriaged issue gets only the id marker, so it stays eligible for both the
  // refinement bot and this workflow's own re-triage.
  const markers = triage.ok ? `${REFINED_MARKER}\n${ID_MARKER(id)}` : ID_MARKER(id);
  await github.rest.issues.createComment({
    owner,
    repo,
    issue_number: issue.number,
    body: `This issue relates to feedback item ${id}.\n\n${markers}`,
  });

  return issue;
}

function buildIssueBody({ id, detail, triage, hosted, keptShots = 0 }) {
  const lines = [
    ID_MARKER(id),
    '> 🛫 Imported automatically from TestFlight beta feedback.',
  ];
  if (!triage.ok) {
    lines.push(
      '',
      '> ⚠️ **Automated triage failed for this issue.** The brief below is the raw',
      '> tester comment. It is labelled `needs-triage` and will be retried on the',
      '> next run; the submission is still held in App Store Connect.',
    );
  }
  lines.push(
    '',
    triage.brief,
    '',
    '---',
    '',
    '### Original tester comment',
    detail.comment ? shared.quote(detail.comment) : '_No written comment — screenshot only._',
    '',
    '### Submission details',
    `- **Submitted:** ${detail.createdDate || 'unknown'}`,
    `- **Device:** ${detail.deviceModel || 'unknown'} · iOS ${detail.osVersion || 'unknown'}`,
    `- **App build:** ${detail.buildPreRelease || detail.buildVersion || 'unknown'}${detail.buildBundleId ? ` (${detail.buildBundleId})` : ''}`,
    `- **Locale / time zone:** ${detail.locale || 'unknown'}${detail.timeZone ? ` · ${detail.timeZone}` : ''}`,
    `- **Connection:** ${detail.connectionType || 'unknown'}${detail.batteryPercentage != null ? ` · battery ${detail.batteryPercentage}%` : ''}`,
  );
  if (hosted.length) {
    lines.push('', '### Screenshots');
    for (const s of hosted) lines.push('', `![${s.name}](${s.url})`);
  } else if (keptShots) {
    lines.push(
      '', '### Screenshots', '',
      `_${keptShots} screenshot(s) kept in App Store Connect (TestFlight → Feedback) until this issue is closed. ` +
      'They are not published here because they can show testers\' connections._',
    );
  }
  return lines.join('\n');
}

module.exports.shortenTitle = shared.shortenTitle;
