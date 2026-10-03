// Shared helpers for the TestFlight feedback and diagnostics workflows.
//
// Both workflows talk to the same two services and open the same shape of
// GitHub issue:
//
//   App Store Connect — ES256 JWT auth, JSON:API paging, app-id resolution.
//   OpenRouter        — one triage call turning raw evidence into a brief.
//   GitHub            — label creation, marker-based de-duplication.
//
// Keeping that here means a fix to the triage request applies to both
// workflows at once. It did not before: the feedback poller silently degraded
// to an untriaged issue while the diagnostics poller kept working, because
// only one of them asked for JSON and neither bounded the model's reasoning
// budget.
//
// Run from a workflow via actions/github-script; see the two callers.

const crypto = require('crypto');

const ASC_BASE = 'https://api.appstoreconnect.apple.com';
const ASC_AUDIENCE = 'appstoreconnect-v1';
const DEFAULT_BUNDLE_ID = 'com.peard.app';
const DEFAULT_MODEL = 'deepseek/deepseek-v4.1-flash';
const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';

// Stamped on a triaged issue so the refinement bot leaves it alone.
const REFINED_MARKER = '<!-- issue-refined -->';

// ---- markers -------------------------------------------------------------

// Feedback and diagnostics each carry their own id marker, so the two pollers
// never see (or claim) one another's issues.
function idMarker(kind, id) {
  return `<!-- tf-${kind}-id: ${id} -->`;
}

function idMarkerRe(kind) {
  return new RegExp(`<!-- tf-${kind}-id: ([^\\s]+) -->`, 'g');
}

function extractId(kind, body) {
  const m = (body || '').match(idMarkerRe(kind));
  return m ? m[1] : null;
}

// ---- config --------------------------------------------------------------

function requireEnv(key) {
  const v = (process.env[key] || '').trim();
  if (!v) throw new Error(`Missing required env ${key}`);
  return v;
}

function loadAscConfig() {
  return {
    keyId: requireEnv('ASC_KEY_ID'),
    issuerId: requireEnv('ASC_ISSUER_ID'),
    privateKey: loadPrivateKey(requireEnv('ASC_KEY_CONTENT')),
    appId: (process.env.ASC_APP_ID || '').trim(),
    bundleId: (process.env.ASC_BUNDLE_ID || '').trim() || DEFAULT_BUNDLE_ID,
  };
}

function loadOpenRouterConfig() {
  return {
    openRouterKey: requireEnv('OPENROUTER_API_KEY'),
    model: (process.env.OPENROUTER_MODEL || '').trim() || DEFAULT_MODEL,
  };
}

function isDryRun() {
  return /^(1|true|yes)$/i.test(process.env.DRY_RUN || '');
}

function publishScreenshots() {
  return /^(1|true|yes)$/i.test(process.env.PUBLISH_SCREENSHOTS || '');
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

// Page through an ASC collection, retrying transient 5xx per page, up to `limit`
// data rows. Returns the rows with a `.included` array carrying every sideloaded
// resource seen across pages.
async function fetchPaged(token, startPath, limit) {
  const out = [];
  const included = [];
  let path = startPath;
  while (path && out.length < limit) {
    let res;
    for (let attempt = 1; attempt <= 3; attempt++) {
      res = await asc(token, path);
      if (res.ok || res.status < 500) break;
      await sleep(2 ** attempt * 1000);
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

// ---- titles --------------------------------------------------------------

// The prompts ask for a title this long; this is the net for one that is not.
// Cut at the last whole word and marked, so a title never ends "on Timeli"
// (#276) and a reader can tell that something was left off.
const MAX_TITLE_LENGTH = 72;

function shortenTitle(title, max = MAX_TITLE_LENGTH) {
  const t = (title || '').replace(/\s+/g, ' ').trim();
  if (t.length <= max) return t;
  const room = t.slice(0, max - 1);
  const space = room.lastIndexOf(' ');
  const cut = space > max / 2 ? room.slice(0, space) : room;
  return `${cut.replace(/[\s,;:.\-–—]+$/, '')}…`;
}

// ---- triage (OpenRouter) -------------------------------------------------

function stripFences(s) {
  const m = s.match(/```(?:json)?\s*([\s\S]*?)```/);
  return (m ? m[1] : s).trim();
}

// Reasoning models on OpenRouter (z-ai/glm-5.3-flash, the current
// OPENROUTER_MODEL, is one) default to their highest reasoning effort and will
// spend the entire completion budget thinking. What comes back is then an empty
// `content` or a JSON object cut off mid-string — exactly the triage failures
// that produced untriaged feedback issues (#300-#302). Triage is extraction, not
// deliberation, so pin the cheapest effort and leave headroom for the answer.
const TRIAGE_MAX_TOKENS = 8192;
const TRIAGE_REASONING_EFFORT = 'low';

// Build the chat-completions body. Images first, then the text prompt.
function buildChatRequest(cfg, { systemPrompt, userPrompt, images = [] }) {
  const content = images.map((shot) => {
    const ext = (shot.name.match(/\.([a-z]+)$/i)?.[1] || 'png').toLowerCase();
    const mime = ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : `image/${ext}`;
    return { type: 'image_url', image_url: { url: `data:${mime};base64,${shot.data.toString('base64')}` } };
  });
  content.push({ type: 'text', text: userPrompt });

  return {
    model: cfg.model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content },
    ],
    max_tokens: TRIAGE_MAX_TOKENS,
    temperature: 0.2,
    reasoning: { effort: TRIAGE_REASONING_EFFORT },
    response_format: { type: 'json_object' },
  };
}

// One triage call, retried on transient failure. Tries the screenshots first;
// if the multimodal request keeps failing, retries text-only so the tester's
// comment still gets triaged. Returns the parsed object, or null when every
// attempt failed (callers decide what a missing triage means).
async function triageJson(cfg, { systemPrompt, userPrompt, images = [], maxAttempts = 3 }, core) {
  const variants = images.length ? [images, []] : [images];
  let lastError;
  for (const [v, imgs] of variants.entries()) {
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) await sleep(2 ** attempt * 1000);
      try {
        const res = await fetch(OPENROUTER_URL, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${cfg.openRouterKey}`,
            'Content-Type': 'application/json',
            'HTTP-Referer': `https://github.com/${process.env.GITHUB_REPOSITORY}`,
          },
          body: JSON.stringify(buildChatRequest(cfg, { systemPrompt, userPrompt, images: imgs })),
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
    if (v + 1 < variants.length) {
      core?.warning(`triage failed with screenshots (${lastError}) — retrying without them.`);
    }
  }
  core?.warning(`triage failed after ${maxAttempts} attempts (${lastError}) — using fallback.`);
  return null;
}

// ---- GitHub --------------------------------------------------------------

// Pin the REST API version on every request (silences Octokit's Sunset
// deprecation warning — 2022-11-28 is itself now deprecated in favour of
// 2026-03-10, see https://docs.github.com/rest/about-the-rest-api/api-versions).
function pinApiVersion(github) {
  github.hook.before('request', (options) => {
    options.headers['x-github-api-version'] = '2026-03-10';
  });
}

async function ensureLabels(github, owner, repo, labels) {
  for (const label of labels) {
    try {
      await github.rest.issues.createLabel({ owner, repo, ...label });
    } catch (err) {
      if (err.status !== 422) throw err; // 422 = already exists
    }
  }
}

// Feedback id → the issue made from it. Carries the state (so a closed issue's
// submission can be purged) and the body (so a degraded issue can be re-triaged).
async function loadProcessedIssues({ github, owner, repo }, { label, kind }) {
  const issues = await github.paginate(github.rest.issues.listForRepo, {
    owner,
    repo,
    state: 'all',
    labels: label,
    per_page: 100,
  });
  const re = idMarkerRe(kind);
  const map = new Map();
  for (const issue of issues) {
    for (const m of (issue.body || '').matchAll(re)) {
      map.set(m[1], {
        number: issue.number,
        state: issue.state,
        body: issue.body || '',
        labels: (issue.labels || []).map((l) => l.name),
      });
    }
  }
  return map;
}

// ---- small helpers -------------------------------------------------------

function quote(text) {
  return text.split('\n').map((l) => `> ${l}`).join('\n');
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

module.exports = {
  ASC_BASE,
  DEFAULT_BUNDLE_ID,
  DEFAULT_MODEL,
  MAX_TITLE_LENGTH,
  OPENROUTER_URL,
  REFINED_MARKER,
  buildChatRequest,
  ensureLabels,
  extractId,
  fetchPaged,
  idMarker,
  loadAscConfig,
  loadOpenRouterConfig,
  loadProcessedIssues,
  isDryRun,
  makeAscToken,
  pinApiVersion,
  publishScreenshots,
  quote,
  resolveAppId,
  shortenTitle,
  sleep,
  stripFences,
  triageJson,
  asc,
};
