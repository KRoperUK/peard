// TestFlight diagnostic signatures → GitHub issues.
//
// Polls the App Store Connect "diagnostic signatures" endpoint for hangs,
// excessive disk writes and slow launches, then turns each new signature into
// a triaged + refined GitHub issue (device/OS distribution and top stack
// frames pulled through). Unlike the feedback poller nothing is deleted or
// mutated in App Store Connect here — there is no API to mark a diagnostic
// signature "resolved" (it isn't a field this resource has), so de-duplication
// relies entirely on the `tf-diag-id` marker already present on GitHub issues
// (see loadProcessedIds below) — closing the issue is enough to stop it being
// re-created; the signature itself simply won't resurface as "new" once its
// id has been seen.
//
// Run from a workflow via actions/github-script:
//   await require('./.github/scripts/testflight-diagnostics.js')({ github, context, core })
//
// Needs (env): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT (.p8 contents),
// OPENROUTER_API_KEY. Optional: ASC_APP_ID or ASC_BUNDLE_ID, OPENROUTER_MODEL,
// DIAGNOSTICS_LIMIT, DIAGNOSTICS_BUILD_LIMIT, DRY_RUN.
//
// `diagnosticSignatures` has no top-level, app-filterable collection endpoint —
// App Store Connect returns 403 FORBIDDEN_ERROR ("has no allowed operations
// defined") for GET /v1/diagnosticSignatures. Signatures are only listable per
// build, so this script resolves the app id, lists its most recent builds, then
// polls diagnostics for each one:
//   GET   /v1/apps?filter[bundleId]=…                  (resolve app id)
//   GET   /v1/builds?filter[app]={id}                  (recent builds)
//   GET   /v1/builds/{id}/diagnosticSignatures          (list, filtered + paginated)
//   GET   /v1/diagnosticSignatures/{id}/logs             (per-signature log detail)
//
// A build's diagnosticSignatures sub-resource only exists once Apple has
// actually collected diagnostics (hangs, excessive disk writes, slow launches)
// for that build. Until then the per-build list endpoint answers 404 NOT_FOUND
// ("There is no resource of type '/v1/builds/{id}/diagnosticSignatures' with
// id '…'") rather than an empty collection — for an app with no reported
// diagnostic issues EVERY build 404s. That's the healthy steady-state, so a
// 404 here is handled as "no data" below, not as a failure.
//
// The App Store Connect OpenAPI spec (developer.apple.com/documentation/
// appstoreconnectapi/diagnosticsignature) only defines three diagnostic types
// — DISK_WRITES, HANGS, LAUNCHES — and only four signature fields —
// diagnosticType, signature, weight, insight. There is no CRASHES or LOGS
// type, and no createdDate/modifiedDate/resolved field on a signature (those
// don't exist on this resource at all — Apple exposes crash reports and raw
// diagnostic logs through different mechanisms). Filtering/requesting any of
// those raises HTTP 400 PARAMETER_ERROR.INVALID.

const crypto = require('crypto');

const ASC_BASE = 'https://api.appstoreconnect.apple.com';
const ASC_AUDIENCE = 'appstoreconnect-v1';
const DEFAULT_BUNDLE_ID = 'com.peard.app';
const DIAGNOSTICS_LABEL = 'testflight-diagnostics';
const ID_MARKER = (id) => `<!-- tf-diag-id: ${id} -->`;
const REFINED_MARKER = '<!-- issue-refined -->';

// The diagnostic types we poll and the presentation/label metadata for each.
// Must match DiagnosticSignature.Attributes.diagnosticType exactly — App Store
// Connect has no CRASHES or LOGS diagnostic type (crash reports and raw logs
// are surfaced through other mechanisms entirely).
const DIAGNOSTIC_TYPES = ['DISK_WRITES', 'HANGS', 'LAUNCHES'];
const TYPE_META = {
    DISK_WRITES: { prefix: 'disk: ', label: 'disk-write' },
    HANGS: { prefix: 'hang: ', label: 'hang' },
    LAUNCHES: { prefix: 'launch: ', label: 'slow-launch' },
};

// Sparse fieldsets we ask App Store Connect to return. A DiagnosticSignature
// only has these four attributes — no createdDate/modifiedDate/resolved (the
// resource has no timestamps and there's no way to mark one resolved via the
// API at all).
const SIGNATURE_FIELDS = ['diagnosticType', 'signature', 'weight', 'insight'].join(',');
const BUILD_FIELDS = ['version', 'preReleaseVersion'].join(',');

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
    core.info(`Polling App Store Connect diagnostic signatures for app ${appId}…`);

    const builds = await listRecentBuilds(token, appId, cfg.buildLimit, core);
    core.info(`Checking ${builds.length} recent build(s) for diagnostic signatures.`);

    const signatures = await listSignatures(token, builds, cfg.limit, core);
    core.info(`Found ${signatures.length} diagnostic signature(s).`);
    if (signatures.length === 0) {
        return;
    }

    const existing = await loadProcessedIds({ github, owner, repo });

    const summary = { created: 0, skipped: 0, failed: 0 };

    for (const sig of signatures) {
        const id = sig.id;
        try {
            if (existing.has(id)) {
                core.info(`${id}: issue already exists (open or closed) — skipping.`);
                summary.skipped++;
                continue;
            }

            const detail = describeSignature(sig, signatures.included);
            const logs = await fetchSignatureLogs(token, id, core);
            const diag = extractLogData(logs, detail, core);

            const triage = await triageSignature(cfg, detail, diag, core);

            if (cfg.dryRun) {
                core.info(`${id}: DRY_RUN — would create "${triage.titlePrefix}${triage.title}" (${detail.diagnosticType}) with ${diag.frames.length} frame(s), ${diag.distribution.length} device/OS row(s).`);
                summary.created++;
                continue;
            }

            const issue = await createIssue(
                { github, owner, repo },
                { id, detail, diag, triage, core }
            );
            core.info(`${id}: opened issue #${issue.number} — ${issue.html_url}`);
            summary.created++;
        } catch (err) {
            summary.failed++;
            core.warning(`${id}: failed — ${err.message} (left in App Store Connect for retry)`);
        }
    }

    core.notice(
        `TestFlight diagnostics: created ${summary.created}, skipped ${summary.skipped}, ` +
        `failed ${summary.failed}.`
    );
    if (summary.failed > 0) {
        core.setFailed(`${summary.failed} signature(s) failed — see logs.`);
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
        limit: Number.parseInt(process.env.DIAGNOSTICS_LIMIT || '200', 10),
        buildLimit: Number.parseInt(process.env.DIAGNOSTICS_BUILD_LIMIT || '10', 10),
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

// Page through an ASC collection, retrying transient 5xx per page, up to `limit`
// data rows. Returns the rows with a non-enumerable-ish `.included` array
// carrying every sideloaded resource seen across pages.
async function fetchPaged(token, startPath, limit) {
    const out = [];
    const included = [];
    let path = startPath;
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

// The most recently uploaded builds for the app — diagnostic signatures are
// only reachable per-build (there is no top-level, app-filterable collection
// endpoint), so this bounds how many builds get polled each run.
async function listRecentBuilds(token, appId, buildLimit, core) {
    const params = new URLSearchParams({
        'filter[app]': appId,
        sort: '-uploadedDate',
        'fields[builds]': BUILD_FIELDS,
        limit: String(Math.min(buildLimit, 200)),
    });
    const res = await asc(token, `/v1/builds?${params.toString()}`);
    if (!res.ok) {
        throw new Error(`list builds failed (${res.status}): ${await res.text()}`);
    }
    const json = await res.json();
    return json.data || [];
}

// Diagnostic signatures are scoped to a single build — GET /v1/diagnosticSignatures
// has no allowed operations (App Store Connect returns 403 FORBIDDEN_ERROR for
// it), so each recent build is polled individually via
// GET /v1/builds/{id}/diagnosticSignatures instead.
//
// Per-build 404s are the normal "nothing collected" answer: Apple only
// materialises a build's diagnosticSignatures resource once diagnostics exist
// for it and returns 404 NOT_FOUND (rather than an empty page) until then, so
// a build with no hang/disk-write/launch data is a skip, not a warning.
async function listSignatures(token, builds, limit, core) {
    const params = new URLSearchParams({
        'filter[diagnosticType]': DIAGNOSTIC_TYPES.join(','),
        'fields[diagnosticSignatures]': SIGNATURE_FIELDS,
        limit: '200',
    });

    const all = [];
    const included = [];
    let polled = 0;
    let noData = 0;
    for (const build of builds) {
        polled++;
        try {
            const data = await fetchPaged(token, `/v1/builds/${build.id}/diagnosticSignatures?${params.toString()}`, limit - all.length);
            for (const sig of data) {
                // Stash the owning build inline (as "included") so downstream
                // shaping (describeSignature) keeps working unchanged.
                sig.relationships = { ...(sig.relationships || {}), build: { data: { type: 'builds', id: build.id } } };
            }
            all.push(...data);
            included.push(build, ...(data.included || []));
        } catch (err) {
            if (err.status === 404) {
                noData++;
                core.info(`build ${buildLabel(build)}: no diagnostics collected yet (404) — skipping.`);
            } else {
                core.warning(`build ${buildLabel(build)}: list diagnostic signatures failed — ${err.message}`);
            }
        }
        if (all.length >= limit) break;
    }

    if (noData > 0) {
        core.info(
            `${noData} of ${polled} polled build(s) have no diagnostics resource — normal unless ` +
            'hangs, excessive disk writes or slow launches have been reported for them.'
        );
    }

    const sliced = all.slice(0, limit);
    sliced.included = included;
    return sliced;
}

// Human-readable build tag for log lines: the build number when the sparse
// fieldset brought it back, else the raw App Store Connect resource id.
function buildLabel(build) {
    const version = build.attributes?.version;
    return version ? `${version} [${build.id}]` : build.id;
}

// Per-signature logs (device/OS + stack frames). Never fatal: a signature with
// no retrievable logs still yields a usable issue from its signature string.
//
// The response is NOT a JSON:API document — it's the plain `diagnosticLogs`
// object: { productData: [ { signatureId, diagnosticInsights, diagnosticLogs:
// [ { callStackTree, diagnosticMetaData } ] } ], version }. There is no `data`
// array, no `attributes`, and no pre-signed download URL to follow — the call
// stacks and metadata are already inline.
async function fetchSignatureLogs(token, id, core) {
    try {
        let res;
        for (let attempt = 1; attempt <= 3; attempt++) {
            res = await asc(token, `/v1/diagnosticSignatures/${id}/logs?limit=10`);
            if (res.ok || res.status < 500) break;
            await new Promise((r) => setTimeout(r, 2 ** attempt * 1000));
        }
        if (!res.ok) {
            core.warning(`${id}: logs fetch returned ${res.status} — continuing without log detail.`);
            return [];
        }
        const json = await res.json();
        const productData = json.productData || [];
        const payloads = [];
        for (const product of productData) {
            for (const log of product.diagnosticLogs || []) {
                payloads.push(log);
            }
        }
        return payloads;
    } catch (err) {
        core.warning(`${id}: logs fetch error (${err.message}) — continuing without log detail.`);
        return [];
    }
}

// ---- shaping -------------------------------------------------------------

function describeSignature(sig, included = []) {
    const a = sig.attributes || {};
    const byRef = (ref) => included.find((i) => i.type === ref?.type && i.id === ref?.id);
    const build = byRef(sig.relationships?.build?.data);
    const buildAttr = build?.attributes || {};

    const buildVersion = buildAttr.preReleaseVersion?.version || buildAttr.version || '';
    const builds = [];
    if (buildVersion || buildAttr.bundleId) {
        builds.push({ version: buildVersion || 'unknown', bundleId: buildAttr.bundleId || '' });
    }

    // `insight` is a nested object (DiagnosticInsight), not a flat field —
    // { insightType: "TREND", direction: ..., referenceVersions: [...] }.
    const insight = a.insight || {};

    return {
        signature: (a.signature || '').trim(),
        insightType: insight.insightType || '',
        insightDirection: insight.direction || '',
        diagnosticType: a.diagnosticType || '',
        weight: a.weight,
        builds,
    };
}

// Walk every parsed log payload, aggregating a device/OS distribution and
// collecting the deepest available ordered stack frames. Degrades gracefully to
// "Unknown"/signature-only when logs are sparse.
function extractLogData(payloads, detail, core) {
    const distMap = new Map(); // "device\u0000os" -> count
    let frames = [];

    for (const payload of payloads) {
        if (!payload || typeof payload !== 'object') continue;

        const { device, os } = extractDeviceOs(payload);
        if (device !== 'Unknown' || os !== 'Unknown') {
            const key = `${device}\u0000${os}`;
            distMap.set(key, (distMap.get(key) || 0) + 1);
        }

        if (frames.length === 0) {
            const found = collectFrames(payload);
            if (found.length) frames = found;
        }
    }

    // Fall back to the signature string when no frames were recoverable.
    if (frames.length === 0 && detail.signature) {
        frames = detail.signature.split('\n').map((l) => l.trim()).filter(Boolean).slice(0, 20);
    }

    const distribution = [...distMap.entries()]
        .map(([key, count]) => {
            const [device, os] = key.split('\u0000');
            return { device, os, count };
        })
        .sort((a, b) => b.count - a.count);

    return { frames, distribution };
}

// Device/OS extraction from a `diagnosticLogs.ProductData.DiagnosticLogs`
// entry's `diagnosticMetaData` (deviceType, osVersion, appVersion, etc.).
function extractDeviceOs(payload) {
    const meta = payload.diagnosticMetaData || {};
    const device = firstString(meta.deviceType) || 'Unknown';
    const os = firstString(meta.osVersion) || 'Unknown';
    return { device, os };
}

function firstString(...vals) {
    for (const v of vals) {
        if (typeof v === 'string' && v.trim()) return v.trim();
    }
    return '';
}

// Recursively gather frame-like objects (those carrying a binary name or symbol)
// in encountered order, following subFrames as the call chain. Capped so a
// pathological tree can't blow up the issue body.
function collectFrames(root, cap = 20) {
    const out = [];
    const seen = new Set();

    const visit = (node) => {
        if (out.length >= cap || node == null) return;
        if (Array.isArray(node)) {
            for (const item of node) visit(item);
            return;
        }
        if (typeof node !== 'object') return;
        if (seen.has(node)) return;
        seen.add(node);

        const binary = firstString(node.binaryName, node.imageName, node.module);
        const symbol = firstString(node.symbol, node.symbolName, node.function, node.rawSymbol);
        if (binary || symbol) {
            out.push(formatFrame(node, binary, symbol));
        }

        // Recurse into likely child-frame containers first (preserves call order),
        // then any other nested arrays/objects.
        for (const key of ['subFrames', 'callStackRootFrames', 'callStacks', 'callStackTree', 'frames']) {
            if (node[key] != null) visit(node[key]);
        }
        for (const [key, value] of Object.entries(node)) {
            if (['subFrames', 'callStackRootFrames', 'callStacks', 'callStackTree', 'frames'].includes(key)) continue;
            if (value && typeof value === 'object') visit(value);
        }
    };

    visit(root);
    return out.slice(0, cap);
}

function formatFrame(node, binary, symbol) {
    const offset = node.offsetIntoBinaryTextSegment ?? node.offset ?? node.address;
    const parts = [];
    if (binary) parts.push(binary);
    if (symbol) {
        parts.push(symbol);
    } else if (offset != null) {
        parts.push(`+ ${offset}`);
    }
    return parts.join(' ').trim() || String(offset ?? '???');
}

// The first frame that looks like it belongs to the app (as opposed to system
// frameworks), used for the mechanical title.
function firstAppFrame(frames) {
    return frames.find((f) => /\b(Peard|PeardCore|PearWidget|PearMessages|PearNotificationService)\b/.test(f)) || null;
}

// ---- triage (OpenRouter) -------------------------------------------------

async function triageSignature(cfg, detail, diag, core) {
    const meta = TYPE_META[detail.diagnosticType] || { prefix: 'diag: ', label: null };

    // Title — mechanical: type prefix + first app frame, else the signature.
    const appFrame = firstAppFrame(diag.frames);
    const rawTitle = appFrame || detail.signature || `${detail.diagnosticType || 'diagnostic'} signature`;
    const title = rawTitle.replace(/\s+/g, ' ').trim().slice(0, 80);

    const brief = await briefFromOpenRouter(cfg, detail, diag, core);

    return {
        titlePrefix: meta.prefix,
        title,
        typeLabel: meta.label,
        brief,
    };
}

async function briefFromOpenRouter(cfg, detail, diag, core) {
    const fs = require('fs');
    let systemPrompt = 'You triage TestFlight diagnostic signatures for an iOS app into GitHub issues.';
    try {
        systemPrompt = fs.readFileSync('.github/prompts/testflight-diagnostics-triage.md', 'utf-8');
    } catch (_) { /* fall back to inline */ }

    const userPrompt = [
        "Triage this TestFlight diagnostic signature into a ready-to-pick-up GitHub issue for Pear'd, an iOS app for sharing one-tap moments, photos and tallies with your favourite people.",
        '',
        'Diagnostic:',
        `- Type: ${detail.diagnosticType || 'unknown'}`,
        `- Insight: ${detail.insightType || 'unknown'}${detail.insightDirection ? ` (${detail.insightDirection})` : ''}`,
        `- Weight (0-1, how critical this signature is): ${detail.weight != null ? detail.weight : 'unknown'}`,
        `- Signature: ${detail.signature || '(none)'}`,
        `- Affected build(s): ${detail.builds.map((b) => b.version).join(', ') || 'unknown'}`,
        '',
        `Top stack frames:\n${diag.frames.length ? diag.frames.map((f, i) => `frame ${i}: ${f}`).join('\n') : '(no frames available)'}`,
        '',
        `Device / OS distribution: ${diag.distribution.length ? diag.distribution.map((d) => `${d.device} on ${d.os} ×${d.count}`).join('; ') : 'unknown'}`,
        '',
        'Return ONLY a JSON object with this shape:',
        '{"brief":"Markdown brief with sections: Problem, Likely cause, Affected areas, Suggested fix"}',
    ].join('\n');

    const parsed = await callOpenRouter(cfg, systemPrompt, userPrompt, core);
    return parsed?.brief || fallbackBrief(detail, diag);
}

async function callOpenRouter(cfg, systemPrompt, userPrompt, core) {
    const maxAttempts = 3;
    let lastError;
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
                        { role: 'user', content: userPrompt },
                    ],
                    max_tokens: 2048,
                    response_format: { type: 'json_object' },
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

function fallbackBrief(detail, diag) {
    return [
        '### Problem',
        `A ${(detail.diagnosticType || 'diagnostic').toLowerCase()} signature was reported by TestFlight${detail.weight != null ? ` (weight ${detail.weight})` : ''}.`,
        '',
        '### Likely cause',
        diag.frames.length
            ? `See the top stack frames below; the first app frame is \`${firstAppFrame(diag.frames) || diag.frames[0]}\`.`
            : '_No stack frames were retrievable — inspect the signature string below._',
        '',
        '### Affected areas',
        '_Automated triage was unavailable; please map the frames to source areas manually._',
        '',
        '### Suggested fix',
        '_Automated triage was unavailable; please refine manually._',
    ].join('\n');
}

// ---- GitHub issue --------------------------------------------------------

async function loadProcessedIds({ github, owner, repo }) {
    const ids = new Set();
    const issues = await github.paginate(github.rest.issues.listForRepo, {
        owner,
        repo,
        state: 'all',
        labels: DIAGNOSTICS_LABEL,
        per_page: 100,
    });
    const re = /<!-- tf-diag-id: ([^\s]+) -->/g;
    for (const issue of issues) {
        for (const m of (issue.body || '').matchAll(re)) ids.add(m[1]);
    }
    return ids;
}

async function ensureLabels(github, owner, repo) {
    const labels = [
        { name: DIAGNOSTICS_LABEL, color: '6F42C1', description: 'Imported from TestFlight diagnostic signatures' },
        { name: 'refined', color: '0E8A16', description: 'Issue has been through refinement' },
        { name: 'hang', color: 'D93F0B', description: 'TestFlight hang report' },
        { name: 'disk-write', color: 'BFDADC', description: 'TestFlight disk write report' },
        { name: 'slow-launch', color: 'D4C5F9', description: 'TestFlight slow-launch report' },
    ];
    for (const label of labels) {
        try {
            await github.rest.issues.createLabel({ owner, repo, ...label });
        } catch (err) {
            if (err.status !== 422) throw err; // 422 = already exists
        }
    }
}

async function createIssue({ github, owner, repo }, { id, detail, diag, triage, core }) {
    await ensureLabels(github, owner, repo);

    const body = buildIssueBody({ id, detail, diag, triage });
    const labels = [DIAGNOSTICS_LABEL, 'refined'];
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
        body: `This issue relates to diagnostic signature ${id}.\n\n${REFINED_MARKER}\n${ID_MARKER(id)}`,
    });

    return issue;
}

function buildIssueBody({ id, detail, diag, triage }) {
    const lines = [
        ID_MARKER(id),
        '> 🩺 Imported automatically from TestFlight diagnostic signatures.',
        '',
        triage.brief,
        '',
        '---',
        '',
        '### Diagnostic details',
        `- **Type:** ${detail.diagnosticType || 'unknown'}`,
        `- **Signature:** \`${detail.signature || 'unknown'}\``,
        `- **Insight:** ${detail.insightType || 'unknown'}${detail.insightDirection ? ` (${detail.insightDirection})` : ''}`,
        `- **Weight (0-1, how critical this signature is):** ${detail.weight != null ? detail.weight : 'unknown'}`,
        '',
        '### Affected builds',
    ];
    if (detail.builds.length) {
        for (const b of detail.builds) {
            lines.push(`- ${b.version}${b.bundleId ? ` (${b.bundleId})` : ''}`);
        }
    } else {
        lines.push('- unknown');
    }

    lines.push('', '### Device & OS distribution', '| Device | OS | Count |', '|--------|----|-------|');
    if (diag.distribution.length) {
        for (const d of diag.distribution) {
            lines.push(`| ${d.device} | ${d.os} | ${d.count} |`);
        }
    } else {
        lines.push('| Unknown | Unknown | — |');
    }

    lines.push('', '### Top frames', '```');
    if (diag.frames.length) {
        diag.frames.forEach((f, i) => lines.push(`frame ${i}: ${f}`));
    } else {
        lines.push('(no stack frames available)');
    }
    lines.push('```');

    return lines.join('\n');
}
