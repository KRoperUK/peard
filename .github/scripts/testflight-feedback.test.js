const test = require('node:test');
const assert = require('node:assert');
const { shortenTitle } = require('./testflight-feedback');

test('a title that fits is left alone, whitespace tidied', () => {
  assert.strictEqual(shortenTitle('  Clear the  phone number\n'), 'Clear the phone number');
});

test('a long title is cut at a whole word and marked (#276)', () => {
  const title = 'Render the edited indicator as a pencil chip matching the Rewound chip on Timeline';
  const short = shortenTitle(title);
  assert.ok(short.length <= 72, `${short.length} characters`);
  assert.ok(short.endsWith('…'));
  assert.ok(title.startsWith(short.slice(0, -1)));
  assert.match(short, /chip…$/);
});

test('no dangling punctuation before the mark', () => {
  // The cut lands just after "last," — the comma goes, not the word.
  assert.match(shortenTitle(`${'word '.repeat(13)}last, trailing words beyond the limit`), /last…$/);
});

test('one unbroken run is still cut to fit', () => {
  const short = shortenTitle('x'.repeat(100));
  assert.strictEqual(short.length, 72);
  assert.ok(short.endsWith('…'));
});
