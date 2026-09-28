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

const crypto = require('crypto');

const ASC_BASE = 'https://api.appstoreconnect.apple.com';
const ASC_AUDIENCE = 'appstoreconnect-v1';
const DEFAULT_BUNDLE_ID = 'com.peard.app';
const FEEDBACK_LABEL = 'testflight-feedback';
const ID_MARKER = (id) => `<!-- tf-feedback-id: ${id} -->`;
const REFINED_MARKER = '<!-- issue-refined -->';

// Attribute fields we want back for each submission (see the API reference).
const SUBMISSION_FIELDS = [
  'createdDate', 'comment', 'deviceModel', 'osVersion', 'locale',
  'timeZone', 'architecture', 'connectionType', 'batteryPercentage',
  'appPlatform', 'devicePlatform', 'deviceFamily', 'buildBundleId',
  'screenshots', 'build',
].join(',');

module.exports = async ({ github, context, core }) => {
  // Pin the REST API version on every request (silences Octokit's Sunset
  // deprecation warning — 2022-11-28 is itself now deprecated in favour of
  // 2026-03-10, see https://docs.github.com/rest/about-the-rest-api/api-versions).
  github.hook.before('request', (options) => {
    options.headers['x-github-api-version'] = '2026-03-10';
  });


  const cfg = loadConfig(core);
  const { owner, repo } = context.repo;

  const token = makeAscToken(cfg);
  const appId = cfg.appId || (await resolveAppId(token, cfg.bundleId, core));
  core.info(`Polling App Store Connect feedback for app ${appId}…`);

  const submissions = await listSubmissions(token, appId, cfg.limit, core);
  core.info(`Found ${submissions.length} screenshot submission(s).`);
  if (submissions.length === 0) {
    return;
  }

  const existing = await loadProcessedIds({ github, owner, repo });

  const summary = { created: 0, skipped: 0, deleted: 0, failed: 0 };

  for (const sub of submissions) {
    const id = sub.id;
    try {
      if (existing.has(id)) {
        summary.skipped++;
        if (cfg.publishScreenshots || existing.get(id) === 'closed') {
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
      core.info(`#${id}: opened issue #${issue.number} — ${issue.html_url}`);
      summary.created++;

      // Triaged → safe to remove from App Store Connect, unless the screenshots
      // only live there; then a later run deletes it once the issue is closed.
      if (hosted.length || shots.length === 0) {
        if (await deleteSubmission(token, id, cfg, core)) summary.deleted++;
      }
    } catch (err) {
      summary.failed++;
      core.warning(`#${id}: failed — ${err.message} (left in App Store Connect for retry)`);
    }
  }

  core.notice(
    `TestFlight feedback: created ${summary.created}, skipped ${summary.skipped}, ` +
    `deleted ${summary.deleted}, failed ${summary.failed}.`
  );
  if (summary.failed > 0) {
    core.setFailed(`${summary.failed} submission(s) failed — see logs.`);
  }
};

// ---- config --------------------------------------------------------------

function loadConfig(core) {
  const need = (key) => {
    const v = (process.env[key] || '').trim();
    if (!v) throw new Error(`Missing required env ${key}`);
    return v;
  };
  return {
    keyId: need('ASC_KEY_ID'),
    issuerId: need('ASC_ISSUER_ID'),
    privateKey: loadPrivateKey(need('ASC_KEY_CONTENT')),
    appId: (process.env.ASC_APP_ID || '').trim(),
    bundleId: (process.env.ASC_BUNDLE_ID || '').trim() || DEFAULT_BUNDLE_ID,
    openRouterKey: need('OPENROUTER_API_KEY'),
    model: (process.env.OPENROUTER_MODEL || '').trim() || 'deepseek/deepseek-v4.1-flash',
    limit: Number.parseInt(process.env.FEEDBACK_LIMIT || '50', 10),
    publishScreenshots: /^(1|true|yes)$/i.test(process.env.PUBLISH_SCREENSHOTS || ''),
    dryRun: /^(1|true|yes)$/i.test(process.env.DRY_RUN || ''),
  };
}

// Accept the .p8 as a real PEM, an escaped-newline PEM, a base64-encoded PEM
// (how the fastlane ASC_KEY_CONTENT secret is commonly stored), or bare base64
// DER.
function loadPrivateKey(raw) {
  let s = raw.trim();
  if (s.includes('\\n')) s = s.replace(/\\n/g, '\n');

  // Already PEM text.
  if (s.includes('PRIVATE KEY')) return crypto.createPrivateKey(s);

  // base64 of a whole .p8 PEM file → decode and use the PEM inside.
  try {
    const decoded = Buffer.from(s.replace(/\s+/g, ''), 'base64').toString('utf8');
    if (decoded.includes('PRIVATE KEY')) return crypto.createPrivateKey(decoded);
  } catch (_) { /* not base64-encoded text — fall through */ }

  // Bare base64 DER → wrap as a PKCS#8 PEM.
  const body = s.replace(/\s+/g, '').match(/.{1,64}/g).join('\n');
  const marker = (edge) => `-----${edge} PRIVATE KEY-----`;
  return crypto.createPrivateKey(`${marker('BEGIN')}\n${body}\n${marker('END')}`);
}

// ---- App Store Connect JWT (ES256) ---------------------------------------

function b64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function makeAscToken({ keyId, issuerId, privateKey }) {
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: issuerId, iat: now, exp: now + 19 * 60, aud: ASC_AUDIENCE };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  // ES256 wants the raw r||s (IEEE P1363) signature, not Node's default DER.
  const sig = crypto.sign('sha256', Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${b64url(sig)}`;
}

// ---- App Store Connect REST ----------------------------------------------

async function asc(token, path, opts = {}) {
  const res = await fetch(`${ASC_BASE}${path}`, {
    ...opts,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      ...(opts.headers || {}),
    },
  });
  return res;
}

async function resolveAppId(token, bundleId, core) {
  const res = await asc(token, `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&fields[apps]=bundleId&limit=1`);
  if (!res.ok) {
    throw new Error(`app lookup failed (${res.status}): ${await res.text()}`);
  }
  const json = await res.json();
  const app = json.data?.[0];
  if (!app) throw new Error(`no app found for bundle id ${bundleId}`);
  core.info(`Resolved bundle ${bundleId} → app id ${app.id}.`);
  return app.id;
}

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

async function fetchPaged(token, query, appId, limit) {
  const out = [];
  const included = [];
  let path = `/v1/apps/${appId}/betaFeedbackScreenshotSubmissions?${query}`;
  while (path && out.length < limit) {
    let res;
    for (let attempt = 1; attempt <= 3; attempt++) {
      res = await asc(token, path);
      if (res.ok || res.status < 500) break;
      await new Promise((r) => setTimeout(r, 2 ** attempt * 1000));
    }
    if (!res.ok) {
      const body = await res.text();
      const err = new Error(`HTTP ${res.status}: ${body}`);
      err.status = res.status;
      throw err;
    }
    const json = await res.json();
    out.push(...(json.data || []));
    included.push(...(json.included || []));
    const next = json.links?.next;
    path = next ? next.replace(ASC_BASE, '') : null;
  }
  out.included = included;
  return out;
}

async function listSubmissions(token, appId, limit, core) {
  const queries = submissionQueries();
  let lastErr;
  for (const [i, query] of queries.entries()) {
    try {
      const data = await fetchPaged(token, query, appId, limit);
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
  const res = await asc(token, `/v1/betaFeedbackScreenshotSubmissions/${id}`, { method: 'DELETE' });
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
    '{"type":"bug|feature|other","title":"short imperative title without a prefix","brief":"Markdown brief with sections: Problem / motivation, Proposed solution, Acceptance criteria, Affected files / areas, Notes / assumptions"}',
  ].join('\n');

  const parsed = await callOpenRouter(cfg, systemPrompt, userPrompt, shots, core);
  const type = ['bug', 'feature', 'other'].includes(parsed?.type) ? parsed.type : 'other';
  const title = (parsed?.title || fallbackTitle(detail)).slice(0, 80);
  const brief = parsed?.brief || fallbackBrief(detail);
  const titlePrefix = type === 'bug' ? 'bug: ' : type === 'feature' ? 'feat: ' : 'feedback: ';
  const typeLabel = type === 'bug' ? 'bug' : type === 'feature' ? 'enhancement' : null;
  return { type, title, brief, titlePrefix, typeLabel };
}

async function callOpenRouter(cfg, systemPrompt, userPrompt, shots, core) {
  const maxAttempts = 3;
  let lastError;

  // Build multimodal user content: images first, then the text prompt.
  const userContent = [];
  for (const shot of (shots || [])) {
    const ext = (shot.name.match(/\.([a-z]+)$/i)?.[1] || 'png').toLowerCase();
    const mime = ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : `image/${ext}`;
    userContent.push({
      type: 'image_url',
      image_url: { url: `data:${mime};base64,${shot.data.toString('base64')}` },
    });
  }
  userContent.push({ type: 'text', text: userPrompt });

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    if (attempt > 1) await new Promise((r) => setTimeout(r, 2 ** attempt * 1000));
    try {
      const res = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${cfg.openRouterKey}`,
          'Content-Type': 'application/json',
          'HTTP-Referer': `https://github.com/${process.env.GITHUB_REPOSITORY}`,
        },
        body: JSON.stringify({
          model: cfg.model,
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: userContent },
          ],
          max_tokens: 2048,
        }),
      });
      if (!res.ok) throw new Error(`OpenRouter ${res.status}: ${await res.text()}`);
      const data = await res.json();
      const content = data.choices?.[0]?.message?.content;
      if (!content) throw new Error('empty content');
      return JSON.parse(stripFences(content));
    } catch (err) {
      lastError = err.message;
    }
  }
  core.warning(`triage failed after ${maxAttempts} attempts (${lastError}) — using fallback.`);
  return null;
}

function stripFences(s) {
  const m = s.match(/```(?:json)?\s*([\s\S]*?)```/);
  return (m ? m[1] : s).trim();
}

function fallbackTitle(detail) {
  const c = detail.comment.replace(/\s+/g, ' ').trim();
  return c ? c.slice(0, 70) : `TestFlight feedback (${detail.deviceModel || 'device'})`;
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

// Feedback id → the state ('open' or 'closed') of the issue made from it.
async function loadProcessedIds({ github, owner, repo }) {
  const ids = new Map();
  const issues = await github.paginate(github.rest.issues.listForRepo, {
    owner,
    repo,
    state: 'all',
    labels: FEEDBACK_LABEL,
    per_page: 100,
  });
  const re = /<!-- tf-feedback-id: ([^\s]+) -->/g;
  for (const issue of issues) {
    for (const m of (issue.body || '').matchAll(re)) ids.set(m[1], issue.state);
  }
  return ids;
}

async function ensureLabels(github, owner, repo) {
  const labels = [
    { name: FEEDBACK_LABEL, color: '1D76DB', description: 'Imported from TestFlight beta feedback' },
    { name: 'refined', color: '0E8A16', description: 'Issue has been through refinement' },
    { name: 'bug', color: 'D73A4A', description: "Something isn't working" },
    { name: 'enhancement', color: 'A2EEEF', description: 'New feature or request' },
  ];
  for (const label of labels) {
    try {
      await github.rest.issues.createLabel({ owner, repo, ...label });
    } catch (err) {
      if (err.status !== 422) throw err; // 422 = already exists
    }
  }
}

async function createIssue({ github, owner, repo }, { id, detail, triage, hosted, keptShots, core }) {
  await ensureLabels(github, owner, repo);

  const body = buildIssueBody({ id, detail, triage, hosted, keptShots });
  const labels = [FEEDBACK_LABEL, 'refined'];
  if (triage.typeLabel) labels.push(triage.typeLabel);

  const { data: issue } = await github.rest.issues.create({
    owner,
    repo,
    title: `${triage.titlePrefix}${triage.title}`,
    body,
    labels,
  });

  // One tracking comment: the human-readable anchor plus the markers. The
  // refined brief itself lives in the issue body (not repeated here), and the
  // issue-refined marker stops the refinement bot from re-refining it.
  await github.rest.issues.createComment({
    owner,
    repo,
    issue_number: issue.number,
    body: `This issue relates to feedback item ${id}.\n\n${REFINED_MARKER}\n${ID_MARKER(id)}`,
  });

  return issue;
}

function buildIssueBody({ id, detail, triage, hosted, keptShots = 0 }) {
  const lines = [
    ID_MARKER(id),
    '> 🛫 Imported automatically from TestFlight beta feedback.',
    '',
    triage.brief,
    '',
    '---',
    '',
    '### Original tester comment',
    detail.comment ? quote(detail.comment) : '_No written comment — screenshot only._',
    '',
    '### Submission details',
    `- **Submitted:** ${detail.createdDate || 'unknown'}`,
    `- **Device:** ${detail.deviceModel || 'unknown'} · iOS ${detail.osVersion || 'unknown'}`,
    `- **App build:** ${detail.buildPreRelease || detail.buildVersion || 'unknown'}${detail.buildBundleId ? ` (${detail.buildBundleId})` : ''}`,
    `- **Locale / time zone:** ${detail.locale || 'unknown'}${detail.timeZone ? ` · ${detail.timeZone}` : ''}`,
    `- **Connection:** ${detail.connectionType || 'unknown'}${detail.batteryPercentage != null ? ` · battery ${detail.batteryPercentage}%` : ''}`,
  ];
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

function quote(text) {
  return text.split('\n').map((l) => `> ${l}`).join('\n');
}
