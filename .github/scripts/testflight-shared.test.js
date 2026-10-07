const test = require('node:test');
const assert = require('node:assert');
const shared = require('./testflight-shared');

// ---- triage request -------------------------------------------------------

test('a triage request bounds reasoning and asks for JSON', () => {
  const body = shared.buildChatRequest(
    { model: 'z-ai/glm-5.3-flash' },
    { systemPrompt: 'sys', userPrompt: 'user' },
  );
  // A reasoning model left at its default effort spends the whole budget
  // thinking and returns empty or truncated JSON — the bug this guards.
  assert.deepStrictEqual(body.reasoning, { effort: 'low' });
  assert.strictEqual(body.response_format.type, 'json_object');
  assert.ok(body.max_tokens > 2048, `${body.max_tokens} leaves no room for the answer`);
  assert.strictEqual(body.model, 'z-ai/glm-5.3-flash');
});

test('screenshots go in ahead of the text prompt', () => {
  const shot = { name: 'IMG_0001.PNG', data: Buffer.from('png-bytes') };
  const body = shared.buildChatRequest(
    { model: 'm' },
    { systemPrompt: 'sys', userPrompt: 'user', images: [shot] },
  );
  const parts = body.messages[1].content;
  assert.deepStrictEqual(parts.map((p) => p.type), ['image_url', 'text']);
  assert.match(parts[0].image_url.url, /^data:image\/png;base64,/);
  assert.strictEqual(parts[1].text, 'user');
});

test('a JPEG screenshot is labelled image/jpeg', () => {
  const body = shared.buildChatRequest(
    { model: 'm' },
    { systemPrompt: 's', userPrompt: 'u', images: [{ name: 'a.jpeg', data: Buffer.from('x') }] },
  );
  assert.match(body.messages[1].content[0].image_url.url, /^data:image\/jpeg;base64,/);
});

test('the text prompt is still a content part with no screenshots', () => {
  const body = shared.buildChatRequest({ model: 'm' }, { systemPrompt: 's', userPrompt: 'u' });
  assert.deepStrictEqual(body.messages[1].content, [{ type: 'text', text: 'u' }]);
});

test('a fenced JSON reply is unwrapped', () => {
  assert.strictEqual(shared.stripFences('```json\n{"a":1}\n```'), '{"a":1}');
  assert.strictEqual(shared.stripFences('{"a":1}'), '{"a":1}');
});

test('when the screenshot call fails, triage retries text-only and admits it', async () => {
  const originalFetch = global.fetch;
  const calls = [];
  global.fetch = async (_url, opts) => {
    calls.push(JSON.parse(opts.body));
    // Fail the call that carried the screenshot, then succeed.
    if (calls.length === 1) return { ok: false, status: 500, text: async () => 'boom' };
    return {
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: '{"title":"t","brief":"b"}' } }] }),
    };
  };

  try {
    // maxAttempts 1 keeps the retry to one call per variant, so no backoff to wait out.
    const out = await shared.triageJson(
      { model: 'm', openRouterKey: 'k' },
      {
        systemPrompt: 'sys',
        userPrompt: 'Tester comment: it broke',
        images: [{ name: 'a.png', data: Buffer.from('x') }],
        maxAttempts: 1,
      },
      null,
    );

    assert.deepStrictEqual(out, { title: 't', brief: 'b' });
    assert.strictEqual(calls.length, 2);

    const first = calls[0].messages[1].content;
    assert.ok(first.some((p) => p.type === 'image_url'), 'the first call should carry the screenshot');

    // The retry must not claim a screenshot it does not have, or the model
    // invents what it cannot see.
    const retry = calls[1].messages[1].content;
    assert.ok(!retry.some((p) => p.type === 'image_url'));
    assert.match(retry.find((p) => p.type === 'text').text, /could not be attached/);
  } finally {
    global.fetch = originalFetch;
  }
});

test('a triage that never succeeds returns null rather than throwing', async () => {
  const originalFetch = global.fetch;
  global.fetch = async () => ({ ok: false, status: 500, text: async () => 'boom' });
  try {
    const out = await shared.triageJson(
      { model: 'm', openRouterKey: 'k' },
      { systemPrompt: 's', userPrompt: 'u', maxAttempts: 1 },
      null,
    );
    assert.strictEqual(out, null);
  } finally {
    global.fetch = originalFetch;
  }
});

// ---- screenshot PII scan --------------------------------------------------

function piiFetch(reply) {
  // One OpenRouter response carrying `reply` as the message content.
  return async () => ({
    ok: true,
    status: 200,
    json: async () => ({ choices: [{ message: { content: reply } }] }),
  });
}

const aShot = { name: 'IMG_0001.PNG', data: Buffer.from('png-bytes') };

test('a clean screenshot is cleared for publishing', async () => {
  const originalFetch = global.fetch;
  global.fetch = piiFetch('{"pii": false, "reason": "generic app UI"}');
  try {
    const v = await shared.scanScreenshotForPII({ model: 'm', openRouterKey: 'k' }, aShot, null);
    assert.strictEqual(v.pii, false);
    assert.strictEqual(v.scanned, true);
  } finally {
    global.fetch = originalFetch;
  }
});

test('a screenshot the model flags as PII is withheld', async () => {
  const originalFetch = global.fetch;
  global.fetch = piiFetch('{"pii": true, "reason": "shows a contact name"}');
  try {
    const v = await shared.scanScreenshotForPII({ model: 'm', openRouterKey: 'k' }, aShot, null);
    assert.strictEqual(v.pii, true);
    assert.strictEqual(v.scanned, true);
    assert.match(v.reason, /contact name/);
  } finally {
    global.fetch = originalFetch;
  }
});

test('the scan fails closed when the model never answers', async () => {
  const originalFetch = global.fetch;
  // Every call 500s: triageJson exhausts its retries and both the image and
  // text-only variants, then returns null. A missing verdict must withhold.
  global.fetch = async () => ({ ok: false, status: 500, text: async () => 'boom' });
  try {
    const v = await shared.scanScreenshotForPII(
      { model: 'm', openRouterKey: 'k' },
      aShot,
      null,
    );
    assert.strictEqual(v.pii, true, 'an unanswered scan must withhold');
    assert.strictEqual(v.scanned, false);
  } finally {
    global.fetch = originalFetch;
  }
});

test('the scan fails closed on a reply with no usable boolean', async () => {
  const originalFetch = global.fetch;
  // Model returns JSON but not a boolean pii field — treated as inconclusive.
  global.fetch = piiFetch('{"verdict": "maybe"}');
  try {
    const v = await shared.scanScreenshotForPII({ model: 'm', openRouterKey: 'k' }, aShot, null);
    assert.strictEqual(v.pii, true);
    assert.strictEqual(v.scanned, false);
  } finally {
    global.fetch = originalFetch;
  }
});

test('scanScreenshots is on by default and only an explicit off disables it', () => {
  const orig = process.env.SCAN_SCREENSHOTS;
  try {
    delete process.env.SCAN_SCREENSHOTS;
    assert.strictEqual(shared.scanScreenshots(), true);
    process.env.SCAN_SCREENSHOTS = 'false';
    assert.strictEqual(shared.scanScreenshots(), false);
    process.env.SCAN_SCREENSHOTS = '0';
    assert.strictEqual(shared.scanScreenshots(), false);
    process.env.SCAN_SCREENSHOTS = 'yes';
    assert.strictEqual(shared.scanScreenshots(), true);
  } finally {
    if (orig === undefined) delete process.env.SCAN_SCREENSHOTS;
    else process.env.SCAN_SCREENSHOTS = orig;
  }
});

// ---- triage usability -----------------------------------------------------

test('a triage needs both a title and a brief to count', () => {
  assert.ok(shared.hasText('Clear the phone number'));
  assert.ok(!shared.hasText('   '));
  assert.ok(!shared.hasText(undefined));
  assert.ok(!shared.hasText(null));
  assert.ok(!shared.hasText(42));
});

// ---- re-triage policy -----------------------------------------------------

test('an untriaged issue is due a re-triage', () => {
  assert.ok(shared.needsRetriage({ labels: ['testflight-feedback', 'needs-triage'] }));
});

test('a refined issue is left alone, with or without needs-triage', () => {
  assert.ok(!shared.needsRetriage({ labels: ['testflight-feedback', 'refined'] }));
  assert.ok(!shared.needsRetriage({ labels: ['refined', 'needs-triage'] }));
});

test('an issue mislabelled refined by an earlier run is still re-triaged', () => {
  // #296, #300-#302: labelled `refined` and de-duplicated, but the brief is the
  // fallback, so nothing else would ever revisit them.
  const degraded = {
    labels: ['testflight-feedback', 'refined'],
    body: `> 🛫 Imported automatically from TestFlight beta feedback.\n\n### Notes / assumptions\n\n_${shared.FALLBACK_SENTINEL}; please refine manually._`,
  };
  assert.ok(shared.needsRetriage(degraded));
});

test('the fallback briefs actually carry the sentinel', () => {
  // Read the two writers back: a sentinel that stops being written would make
  // the repair above silently stop matching.
  for (const file of ['testflight-feedback.js', 'testflight-diagnostics.js']) {
    const source = require('node:fs').readFileSync(require('node:path').join(__dirname, file), 'utf8');
    assert.match(source, /FALLBACK_SENTINEL/, `${file} must use the shared sentinel`);
  }
});

test('an issue with neither label is not picked up', () => {
  assert.ok(!shared.needsRetriage({ labels: ['testflight-feedback'] }));
  assert.ok(!shared.needsRetriage({}));
});

// ---- markers --------------------------------------------------------------

test('each poller reads only its own id marker', () => {
  const body = `<!-- tf-feedback-id: ABC -->\n<!-- tf-diag-id: XYZ -->`;
  assert.strictEqual(shared.extractId('feedback', body), 'ABC');
  assert.strictEqual(shared.extractId('diag', body), 'XYZ');
  assert.strictEqual(shared.extractId('feedback', 'no marker here'), null);
});

test('loadProcessedIssues maps id to state, labels and body', async () => {
  const issues = [
    {
      number: 7,
      state: 'open',
      body: '<!-- tf-feedback-id: ABC -->',
      labels: [{ name: 'testflight-feedback' }, { name: 'needs-triage' }],
    },
    { number: 8, state: 'closed', body: '<!-- tf-diag-id: XYZ -->', labels: [] },
  ];
  const github = { paginate: async () => issues, rest: { issues: { listForRepo: {} } } };

  const feedback = await shared.loadProcessedIssues({ github, owner: 'o', repo: 'r' }, { label: 'l', kind: 'feedback' });
  assert.deepStrictEqual([...feedback.keys()], ['ABC']);
  assert.strictEqual(feedback.get('ABC').state, 'open');
  assert.strictEqual(feedback.get('ABC').number, 7);
  assert.ok(shared.needsRetriage(feedback.get('ABC')));

  const diag = await shared.loadProcessedIssues({ github, owner: 'o', repo: 'r' }, { label: 'l', kind: 'diag' });
  assert.deepStrictEqual([...diag.keys()], ['XYZ']);
  assert.strictEqual(diag.get('XYZ').state, 'closed');
});

// ---- labels ---------------------------------------------------------------

test('ensureLabels ignores an already-existing label but rethrows others', async () => {
  const created = [];
  const github = {
    rest: {
      issues: {
        createLabel: async (args) => {
          created.push(args.name);
          if (args.name === 'exists') {
            const err = new Error('already exists');
            err.status = 422;
            throw err;
          }
          if (args.name === 'boom') throw new Error('server exploded');
        },
      },
    },
  };

  await shared.ensureLabels(github, 'o', 'r', [{ name: 'exists' }, { name: 'new' }]);
  assert.deepStrictEqual(created, ['exists', 'new']);

  await assert.rejects(
    shared.ensureLabels(github, 'o', 'r', [{ name: 'boom' }]),
    /server exploded/,
  );
});

// ---- titles ---------------------------------------------------------------

test('a title that fits is left alone, whitespace tidied', () => {
  assert.strictEqual(shared.shortenTitle('  Clear the  phone number\n'), 'Clear the phone number');
});

test('a long title is cut at a whole word and marked (#276)', () => {
  const title = 'Render the edited indicator as a pencil chip matching the Rewound chip on Timeline';
  const short = shared.shortenTitle(title);
  assert.ok(short.length <= 72, `${short.length} characters`);
  assert.ok(short.endsWith('…'));
  assert.ok(title.startsWith(short.slice(0, -1)));
  assert.match(short, /chip…$/);
});

test('no dangling punctuation before the mark', () => {
  // The cut lands just after "last," — the comma goes, not the word.
  assert.match(shared.shortenTitle(`${'word '.repeat(13)}last, trailing words beyond the limit`), /last…$/);
});

test('one unbroken run is still cut to fit', () => {
  const short = shared.shortenTitle('x'.repeat(100));
  assert.strictEqual(short.length, 72);
  assert.ok(short.endsWith('…'));
});

test('a tester\'s own label is dropped from a fallback title', () => {
  assert.strictEqual(
    shared.stripLeadingLabel('Bug. When deleting moment from timeline, confirmation bubble always appears'),
    'When deleting moment from timeline, confirmation bubble always appears',
  );
  assert.strictEqual(
    shared.stripLeadingLabel('Feat / idea. Improve data handling and support for low data mode'),
    'Improve data handling and support for low data mode',
  );
});

test('a genuine imperative is not mistaken for a label', () => {
  assert.strictEqual(shared.stripLeadingLabel('Fix the progress bar'), 'Fix the progress bar');
  assert.strictEqual(shared.stripLeadingLabel('Requested a new thing'), 'Requested a new thing');
  assert.strictEqual(shared.stripLeadingLabel('Just some normal feedback'), 'Just some normal feedback');
});

test('a comment that is only a label keeps it', () => {
  assert.strictEqual(shared.stripLeadingLabel('Bug'), 'Bug');
  assert.strictEqual(shared.stripLeadingLabel('Bug.'), 'Bug.');
});

// ---- misc -----------------------------------------------------------------

test('quote prefixes every line', () => {
  assert.strictEqual(shared.quote('one\ntwo'), '> one\n> two');
});
