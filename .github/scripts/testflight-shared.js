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

const REFINED_LABEL = 'refined';
const NEEDS_TRIAGE_LABEL = 'needs-triage';

// Written into a brief when triage did not happen. It is the one durable mark of
// a degraded issue, which matters because earlier runs labelled those `refined`
// and de-duplicated them — a label check alone would never revisit them.
const FALLBACK_SENTINEL = 'Automated triage was unavailable';

// An issue is due a re-triage when triage never actually succeeded: it is
// labelled `needs-triage` and never gained `refined`, or its brief still carries
// the fallback sentinel (the issues from before this was fixed).
function needsRetriage(issue) {
  const labels = issue?.labels || [];
  const degraded = (issue?.body || '').includes(FALLBACK_SENTINEL);
  if (labels.includes(REFINED_LABEL) && !degraded) return false;
  return labels.includes(NEEDS_TRIAGE_LABEL) || degraded;
}

// A triage is usable only when it carries the text the caller needs. A partial
// object is a failure, not a lesser success: an issue half-triaged and labelled
// `refined` is worse than an honest `needs-triage`.
function hasText(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

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
  // matchAll, not match: a /g regex makes match return whole matches, not groups.
  for (const m of (body || '').matchAll(idMarkerRe(kind))) return m[1];
  return null;
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

// Whether the PII scan gate runs. On by default — it is the whole point of the
// screenshot-publish path — and only turned off explicitly, which falls back to
// the old withhold-everything-unless-PUBLISH_SCREENSHOTS behaviour.
function scanScreenshots() {
  return !/^(0|false|no)$/i.test(process.env.SCAN_SCREENSHOTS || '');
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

// Testers often open with a label of their own — "Bug.", "Fix.", "Feat / idea."
// — which is useful context in the comment but noise at the front of a title,
// where it reads like a triage decision nobody made. The label only counts when
// punctuation follows it, so a genuine imperative ("Fix the progress bar") is
// left alone.
const LEADING_LABEL = /^\s*(?:(?:bug|fix|feature|feat|idea|issue|problem|request|suggestion|feedback|question)\b[\s/]*)+[.:–—-]+\s*/i;

function stripLeadingLabel(text) {
  const m = text.match(LEADING_LABEL);
  if (!m) return text;
  const rest = text.slice(m[0].length);
  // Never strip to nothing: a comment that is only the word "Bug" keeps it.
  return rest.trim().length > 3 ? rest : text;
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
    // The caller's prompt says the screenshots are attached. On the text-only
    // retry they are not, and a model that believes otherwise invents what it
    // cannot see, so say so.
    const droppedImages = images.length > 0 && imgs.length === 0;
    const prompt = droppedImages
      ? `${userPrompt}\n\nNote: the screenshot(s) could not be attached to this request. Triage from the written comment alone, and say in the brief that the finding is uncertain because the screenshots were unavailable.`
      : userPrompt;
    if (droppedImages) core?.info('Retrying triage without the screenshots.');

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
          body: JSON.stringify(buildChatRequest(cfg, { systemPrompt, userPrompt: prompt, images: imgs })),
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
  // Not a warning: the caller decides what a missing triage means, and both
  // callers treat it as a failure worth failing the run over.
  core?.info(`OpenRouter triage failed after ${maxAttempts} attempts (${lastError}).`);
  return null;
}

// ---- screenshot PII scan -------------------------------------------------

// The repo is public, so a tester's screenshot is only ever attached to an
// issue when it is provably clean: it can show the other person in the
// connection — their name, avatar, messages — which must not be published.
//
// The scan is LOCAL-ONLY: the image is OCRed on the runner with the `tesseract`
// binary and the recognised text is checked with regexes plus a small vendored
// first-name list. No image or text leaves the runner for the scan, and it needs
// no secret. (The triage call still sends screenshots to OpenRouter as before;
// that is unchanged and independent of this gate.)
//
// It FAILS CLOSED. Anything short of a confident, clean read withholds the
// image: tesseract missing, an OCR error or timeout, a low-confidence read, or
// too little text to judge (a picture with no readable text could be a face).
// The scan cannot see faces/avatars that carry no text; that is the residual
// risk, and why a clean verdict needs enough legible text to have been a UI.
const MIN_OCR_WORDS = 3;
const MIN_OCR_CONFIDENCE = 60; // mean per-word tesseract confidence, 0-100
const OCR_TIMEOUT_MS = 30000;

// Common given names. Deliberately omits names that are also everyday words or
// UI vocabulary (will, mark, may, grace, rose, bill, jack, ...) to keep false
// positives down; a miss still has to get past the other detectors.
const FIRST_NAMES = new Set((
  'aaron adam adrian alan albert alex alexander alice alicia amanda amber amy andrew andy angela anna anne ' +
  'anthony ashley barbara ben benjamin beth betty brandon brian bruce caroline carol catherine charles ' +
  'charlotte chloe chris christine christopher claire daniel danielle darren dave david deborah diane ' +
  'donna dorothy douglas dylan edward eleanor elizabeth ella ellie emily emma eric ethan eva evelyn ' +
  'fiona frances gareth gary gemma george gillian gordon hannah harry heather helen henry holly ian isaac ' +
  'isabel jacob james jamie jane janet jason jean jennifer jenny jeremy jessica jill joanna joe john ' +
  'jonathan joseph josh joshua judith julia julie karen kate katherine kathleen katie keith kelly ken ' +
  'kevin kieran kim kirsty laura lauren lee lewis liam linda lisa liz louise lucy luke lynn margaret ' +
  'maria marie martin mary matthew megan melissa michael michelle mike natalie nathan neil nicholas ' +
  'nicola nicole noah olivia oliver owen patricia patrick paul paula peter philip rachel rebecca richard ' +
  'robert robin roger ross ruth ryan sam samantha samuel sandra sarah scott sean sharon simon sophie ' +
  'stephanie stephen steve steven stuart susan tanya teresa thomas tim timothy tina tom tony tracy ' +
  'victoria vincent wayne william zoe'
).split(' '));

// Capitalised UI words that may legitimately sit next to each other (Title Case
// labels). A capitalised pair of anything NOT in here is treated as a possible
// full name.
const UI_WORDS = new Set((
  'about account activity add all amount app apple back bottle cancel cup daily day days delete details ' +
  'done drink drinks edit enable enabled feedback filter general glass goal goals health help history home ' +
  'hydration intake item items litre litres log monday tuesday wednesday thursday friday saturday sunday ' +
  'january february march april june july august september october november december menu month more ' +
  'next notifications off ok on open peard pear per preferences privacy progress remind reminder reminders ' +
  'reset save search settings share sign start stats streak sync target team testflight today total ' +
  'tracker units update version water week weekly year yesterday'
).split(' '));

// Each detector: [reason, test(text) -> boolean]. Reasons are CATEGORIES only —
// never the matched text, because the reason is logged and written into a
// public issue body.
const PII_DETECTORS = [
  ['email address', (t) => /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/.test(t)],
  ['phone number', (t) => (t.match(/\+?\d[\d\s().-]{7,}\d/g) || []).some((m) => m.replace(/\D/g, '').length >= 9)],
  ['@handle', (t) => /(?:^|[^\w@])@[A-Za-z0-9_.]{2,}/.test(t)],
  ['URL', (t) => /\bhttps?:\/\/\S+|\bwww\.\S+/i.test(t)],
  ['postal address', (t) =>
    /\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b/.test(t) ||
    /\b\d{1,5}\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\s+(?:Street|St|Road|Rd|Avenue|Ave|Lane|Ln|Close|Drive|Dr|Way|Court|Ct)\b/.test(t)],
  ['labelled name', (t) =>
    /\b(?:[Nn]ame|[Ff]rom|[Hh]i|[Hh]ello|[Dd]ear|[Pp]artner|[Ii]nvited by|[Ss]hared by|[Ss]ent by)\b\s*[:,-]?\s+[A-Z][a-z]{2,}/.test(t)],
  ['first name', (t) => (t.match(/[A-Za-z]+/g) || []).some((w) => FIRST_NAMES.has(w.toLowerCase()))],
  ['possible full name', (t) => {
    const lines = t.split('\n');
    for (const line of lines) {
      const words = line.match(/[A-Za-z]+/g) || [];
      for (let i = 0; i + 1 < words.length; i++) {
        const [a, b] = [words[i], words[i + 1]];
        const cap = (w) => /^[A-Z][a-z]{2,}$/.test(w) && !UI_WORDS.has(w.toLowerCase());
        if (cap(a) && cap(b)) return true;
      }
    }
    return false;
  }],
];

// Pure: text in, list of PII categories found (empty when none).
function detectPII(text) {
  const t = String(text || '');
  return PII_DETECTORS.filter(([, test]) => test(t)).map(([reason]) => reason);
}

// Parse `tesseract <img> stdout tsv` into { text, words, confidence }.
// Only real word rows (level 5, conf >= 0, non-empty text) count.
function parseTesseractTsv(tsv) {
  const lines = [];
  const confs = [];
  const byLine = new Map();
  for (const row of String(tsv || '').split('\n').slice(1)) {
    const c = row.split('\t');
    if (c.length < 12 || c[0] !== '5') continue;
    const conf = Number.parseFloat(c[10]);
    const word = c.slice(11).join('\t').trim();
    if (!word || !(conf >= 0)) continue;
    const key = `${c[2]}-${c[3]}-${c[4]}`;
    if (!byLine.has(key)) {
      byLine.set(key, []);
      lines.push(key);
    }
    byLine.get(key).push(word);
    confs.push(conf);
  }
  const mean = confs.length ? confs.reduce((a, b) => a + b, 0) / confs.length : 0;
  return { text: lines.map((k) => byLine.get(k).join(' ')).join('\n'), words: confs.length, confidence: mean };
}

// Default OCR runner: tesseract on a 0700 temp dir, killed after the timeout.
// Rejects with err.code === 'ENOENT' when the binary is not installed.
function runTesseract(bin, imagePath, timeoutMs) {
  const { execFile } = require('child_process');
  return new Promise((resolve, reject) => {
    execFile(
      bin,
      [imagePath, 'stdout', '-l', 'eng', 'tsv'],
      { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, encoding: 'utf8' },
      (err, stdout) => (err ? reject(err) : resolve(stdout)),
    );
  });
}

// OCR one screenshot -> { text, words, confidence }. Throws on any failure.
async function ocrScreenshot(shot, { bin = 'tesseract', timeoutMs = OCR_TIMEOUT_MS, run = runTesseract } = {}) {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tf-ocr-'));
  try {
    const file = path.join(dir, 'shot.img');
    fs.writeFileSync(file, shot.data, { mode: 0o600 });
    return parseTesseractTsv(await run(bin, file, timeoutMs));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// Scan one screenshot. Returns { pii, reason, scanned }.
//
// pii:false is returned ONLY for a confident read that found nothing. Every
// other outcome is { pii: true } — scanned:true with a category reason when PII
// was found (scanned-dirty), scanned:false with a cause when the scan could not
// give a confident answer (scan-unavailable). A tester image is NEVER published
// on a guess.
async function scanScreenshotForPII(cfg, shot, core, { ocr = ocrScreenshot } = {}) {
  let read;
  try {
    read = await ocr(shot);
  } catch (err) {
    const why = err && err.code === 'ENOENT' ? 'tesseract not installed'
      : err && (err.killed || err.signal) ? 'OCR timed out'
      : 'OCR error';
    core?.warning(`PII scan unavailable for ${shot.name} (${why}) — withholding.`);
    return { pii: true, reason: `scan unavailable: ${why}`, scanned: false };
  }

  if (!read || !(read.words >= MIN_OCR_WORDS)) {
    core?.warning(`PII scan inconclusive for ${shot.name} (too little readable text) — withholding.`);
    return { pii: true, reason: 'scan unavailable: too little readable text', scanned: false };
  }
  if (!(read.confidence >= MIN_OCR_CONFIDENCE)) {
    core?.warning(`PII scan inconclusive for ${shot.name} (low OCR confidence) — withholding.`);
    return { pii: true, reason: 'scan unavailable: low OCR confidence', scanned: false };
  }

  const found = detectPII(read.text);
  if (found.length) return { pii: true, reason: `contains ${found.join(', ')}`, scanned: true };
  return { pii: false, reason: 'no PII detected', scanned: true };
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
  FALLBACK_SENTINEL,
  MAX_TITLE_LENGTH,
  NEEDS_TRIAGE_LABEL,
  OPENROUTER_URL,
  REFINED_LABEL,
  REFINED_MARKER,
  buildChatRequest,
  ensureLabels,
  extractId,
  fetchPaged,
  hasText,
  idMarker,
  loadAscConfig,
  loadOpenRouterConfig,
  loadProcessedIssues,
  isDryRun,
  makeAscToken,
  needsRetriage,
  pinApiVersion,
  publishScreenshots,
  quote,
  resolveAppId,
  scanScreenshots,
  detectPII,
  ocrScreenshot,
  parseTesseractTsv,
  scanScreenshotForPII,
  shortenTitle,
  sleep,
  stripFences,
  stripLeadingLabel,
  triageJson,
  asc,
};
