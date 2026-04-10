/**
 * Unit tests for dashboard app.js pure functions.
 * Run: node tests/dashboard.test.js
 *
 * Uses Node.js built-in assert module — no npm install needed.
 */

const assert = require('assert');

// ─── Stub browser globals ──────────────────────────────────────────────────
global.window = { EXPERIMENTS: [], EXPERIMENTS_GENERATED: [] };
global.document = {
  addEventListener: () => {},
  getElementById: () => ({ innerHTML: '', classList: { add: () => {}, remove: () => {} } }),
  body: { innerHTML: '' },
};
global.location = { hash: '#table' };
global.Chart = function() { return { destroy: () => {} }; };

// Load the JS file by evaluating it (app.js uses globals, not modules)
const fs = require('fs');
const path = require('path');
const appPath = path.join(__dirname, '..', 'dashboard', 'app.js');
const appCode = fs.readFileSync(appPath, 'utf-8');

// Execute in this context to get functions defined globally
eval(appCode);

// ─── Tests ─────────────────────────────────────────────────────────────────
let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log('  PASS: ' + name);
  } catch (e) {
    failed++;
    console.error('  FAIL: ' + name);
    console.error('        ' + e.message);
  }
}

console.log('\n=== Dashboard JS Tests ===\n');

// --- escHtml ---
console.log('escHtml:');

test('escapes ampersands', () => {
  assert.strictEqual(escHtml('a & b'), 'a &amp; b');
});

test('escapes angle brackets', () => {
  assert.strictEqual(escHtml('<script>'), '&lt;script&gt;');
});

test('escapes double quotes', () => {
  assert.strictEqual(escHtml('a "b" c'), 'a &quot;b&quot; c');
});

test('returns empty string for null', () => {
  assert.strictEqual(escHtml(null), '');
});

test('returns empty string for undefined', () => {
  assert.strictEqual(escHtml(undefined), '');
});

test('converts numbers to string', () => {
  assert.strictEqual(escHtml(42), '42');
});

test('handles empty string', () => {
  assert.strictEqual(escHtml(''), '');
});

test('handles string with no special chars', () => {
  assert.strictEqual(escHtml('hello world'), 'hello world');
});

// --- safeNum ---
console.log('\nsafeNum:');

test('formats number with default 2 decimals', () => {
  assert.strictEqual(safeNum(3.14159), '3.14');
});

test('formats number with specified decimals', () => {
  assert.strictEqual(safeNum(3.14159, 4), '3.1416');
});

test('returns -- for null', () => {
  assert.strictEqual(safeNum(null), '--');
});

test('returns -- for undefined', () => {
  assert.strictEqual(safeNum(undefined), '--');
});

test('returns -- for NaN', () => {
  assert.strictEqual(safeNum(NaN), '--');
});

test('formats zero correctly', () => {
  assert.strictEqual(safeNum(0), '0.00');
});

test('formats integer with decimals', () => {
  assert.strictEqual(safeNum(5, 1), '5.0');
});

// --- perfVal ---
console.log('\nperfVal:');

test('extracts avg from perf counter', () => {
  const perf = { DPCTimePct: { avg: 0.15, min: 0, max: 0.5 } };
  assert.strictEqual(perfVal(perf, 'DPCTimePct'), 0.15);
});

test('returns null for missing key', () => {
  const perf = { DPCTimePct: { avg: 0.15 } };
  assert.strictEqual(perfVal(perf, 'InterruptTimePct'), null);
});

test('returns null for null perf', () => {
  assert.strictEqual(perfVal(null, 'DPCTimePct'), null);
});

test('returns null for undefined perf', () => {
  assert.strictEqual(perfVal(undefined, 'DPCTimePct'), null);
});

test('returns null when avg is null', () => {
  const perf = { DPCTimePct: { avg: null } };
  assert.strictEqual(perfVal(perf, 'DPCTimePct'), null);
});

test('returns 0 when avg is 0 (not null)', () => {
  const perf = { DPCTimePct: { avg: 0, min: 0, max: 0 } };
  assert.strictEqual(perfVal(perf, 'DPCTimePct'), 0);
});

// --- getStatus ---
console.log('\ngetStatus:');

test('returns PASS for passing latencymon', () => {
  assert.strictEqual(getStatus({ latencymon: { result: 'PASS' } }), 'PASS');
});

test('returns REVIEW for failing latencymon', () => {
  assert.strictEqual(getStatus({ latencymon: { result: 'FAIL' } }), 'REVIEW');
});

test('returns N/A when no latencymon', () => {
  assert.strictEqual(getStatus({}), 'N/A');
});

test('returns N/A when latencymon is null', () => {
  assert.strictEqual(getStatus({ latencymon: null }), 'N/A');
});

// --- getAllTags ---
console.log('\ngetAllTags:');

test('collects unique tags from experiments', () => {
  window.EXPERIMENTS = [
    { id: 'a', tags: ['perf', 'network'] },
    { id: 'b', tags: ['perf', 'gpu'] },
    { id: 'c', tags: ['network'] },
  ];
  const tags = getAllTags();
  assert.deepStrictEqual(tags, ['gpu', 'network', 'perf']);
});

test('returns empty array when no tags', () => {
  window.EXPERIMENTS = [{ id: 'a' }, { id: 'b', tags: [] }];
  const tags = getAllTags();
  assert.deepStrictEqual(tags, []);
});

test('handles missing tags property', () => {
  window.EXPERIMENTS = [{ id: 'a' }];
  const tags = getAllTags();
  assert.deepStrictEqual(tags, []);
});

// --- getMetricValue ---
console.log('\ngetMetricValue:');

test('gets DPCTimePct', () => {
  const exp = { performance: { DPCTimePct: { avg: 0.12 } } };
  assert.strictEqual(getMetricValue(exp, 'DPCTimePct'), 0.12);
});

test('gets InterruptTimePct', () => {
  const exp = { performance: { InterruptTimePct: { avg: 0.05 } } };
  assert.strictEqual(getMetricValue(exp, 'InterruptTimePct'), 0.05);
});

test('gets FPSAvg from frameTiming', () => {
  const exp = { frameTiming: { fps: { avg: 144.5 }, frameTimeMs: {} } };
  assert.strictEqual(getMetricValue(exp, 'FPSAvg'), 144.5);
});

test('gets FrameTimeP99 from frameTiming', () => {
  const exp = { frameTiming: { frameTimeMs: { p99: 22.1 }, fps: {} } };
  assert.strictEqual(getMetricValue(exp, 'FrameTimeP99'), 22.1);
});

test('returns null for missing metric', () => {
  assert.strictEqual(getMetricValue({}, 'DPCTimePct'), null);
});

test('returns null for missing performance', () => {
  assert.strictEqual(getMetricValue({}, 'ProcessorTimePct'), null);
});

// --- getMetricLabel ---
console.log('\ngetMetricLabel:');

test('maps DPCTimePct to display label', () => {
  assert.strictEqual(getMetricLabel('DPCTimePct'), '% DPC Time');
});

test('maps FPSAvg to display label', () => {
  assert.strictEqual(getMetricLabel('FPSAvg'), 'FPS (avg)');
});

test('returns key as-is for unknown metric', () => {
  assert.strictEqual(getMetricLabel('UnknownMetric'), 'UnknownMetric');
});

// --- frameTimeColor ---
console.log('\nframeTimeColor:');

test('returns green for sub-8ms', () => {
  assert.strictEqual(frameTimeColor(5), '#10b981');
});

test('returns amber for 8-16ms', () => {
  assert.strictEqual(frameTimeColor(12), '#f59e0b');
});

test('returns red for >16ms', () => {
  assert.strictEqual(frameTimeColor(20), '#ef4444');
});

test('returns muted for null', () => {
  assert.strictEqual(frameTimeColor(null), 'var(--muted)');
});

// --- fmtDate ---
console.log('\nfmtDate:');

test('returns -- for null date', () => {
  assert.strictEqual(fmtDate(null), '--');
});

test('returns -- for empty string', () => {
  assert.strictEqual(fmtDate(''), '--');
});

test('formats valid ISO date', () => {
  const result = fmtDate('2026-03-29T19:23:13');
  assert.ok(result.length > 5, 'formatted date should have content');
  assert.ok(result.includes('2026'), 'should contain year');
});

// --- deepMerge ---
console.log('\ndeepMerge:');

test('merges flat objects', () => {
  const result = deepMerge({ a: 1, b: 2 }, { b: 3, c: 4 });
  assert.deepStrictEqual(result, { a: 1, b: 3, c: 4 });
});

test('deep merges nested objects', () => {
  const result = deepMerge({ a: { x: 1, y: 2 } }, { a: { y: 3, z: 4 } });
  assert.deepStrictEqual(result, { a: { x: 1, y: 3, z: 4 } });
});

test('does not mutate base', () => {
  const base = { a: 1 };
  deepMerge(base, { b: 2 });
  assert.deepStrictEqual(base, { a: 1 });
});

// --- Summary ---
console.log('\n' + '='.repeat(40));
console.log('Results: ' + passed + ' passed, ' + failed + ' failed');
console.log('='.repeat(40) + '\n');
process.exit(failed > 0 ? 1 : 0);
