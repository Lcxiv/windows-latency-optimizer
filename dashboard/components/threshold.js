// ============================================================
// THRESHOLD ENGINE — Color-coded metric evaluation
// ============================================================
// Defines good/warn/bad boundaries per metric. Provides functions
// to evaluate values and return state, CSS classes, and Chart.js
// threshold line overlays.
// ============================================================

// Threshold definitions — metrics and their good/warn/bad boundaries
// "inverted" means higher is better (e.g., FPS)
var THRESHOLDS = {
  DPCTimePct:         { good: 0.05, warn: 0.15, bad: 0.5,   unit: '%',   label: 'DPC Time' },
  InterruptTimePct:   { good: 0.1,  warn: 0.3,  bad: 1.0,   unit: '%',   label: 'Interrupt Time' },
  ProcessorTimePct:   { good: 5,    warn: 15,   bad: 40,    unit: '%',   label: 'CPU Time' },
  FrameTimeP99:       { good: 8,    warn: 16.67, bad: 33.3, unit: 'ms',  label: 'Frame Time p99' },
  FPSAvg:             { good: 144,  warn: 60,   bad: 30,    unit: 'fps', label: 'FPS', inverted: true },
  PagesSec:           { good: 50,   warn: 200,  bad: 1000,  unit: '/s',  label: 'Page Faults' },
  ContextSwitchesSec: { good: 5000, warn: 15000, bad: 50000, unit: '/s', label: 'Context Switches' }
};

/**
 * Evaluate a metric value against its thresholds.
 * @param {string} metricKey — key into THRESHOLDS
 * @param {number|null} value — the metric value to evaluate
 * @returns {'good'|'warn'|'bad'|'neutral'} threshold state
 */
function evaluateThreshold(metricKey, value) {
  var t = THRESHOLDS[metricKey];
  if (!t || value == null || isNaN(value)) return 'neutral';

  if (t.inverted) {
    // Higher is better (e.g., FPS)
    if (value >= t.good) return 'good';
    if (value >= t.warn) return 'warn';
    return 'bad';
  }

  // Lower is better (default)
  if (value <= t.good) return 'good';
  if (value <= t.warn) return 'warn';
  return 'bad';
}

/**
 * Get CSS class for threshold state.
 * @param {string} metricKey
 * @param {number|null} value
 * @returns {string} CSS class: 'threshold-good', 'threshold-warn', 'threshold-bad', or ''
 */
function thresholdClass(metricKey, value) {
  var state = evaluateThreshold(metricKey, value);
  if (state === 'neutral') return '';
  return 'threshold-' + state;
}

/**
 * Get the threshold definition for a metric.
 * @param {string} metricKey
 * @returns {object|null} threshold definition or null
 */
function getThreshold(metricKey) {
  return THRESHOLDS[metricKey] || null;
}

/**
 * Get the color associated with a threshold state.
 * Uses the dashboard's COLORS palette when available.
 * @param {string} state — 'good', 'warn', 'bad', or 'neutral'
 * @returns {string} hex color
 */
function thresholdColor(state) {
  switch (state) {
    case 'good': return '#10b981';
    case 'warn': return '#f59e0b';
    case 'bad':  return '#ef4444';
    default:     return '#64748b';
  }
}

/**
 * Evaluate a metric and return its color directly.
 * Convenience for inline styling.
 * @param {string} metricKey
 * @param {number|null} value
 * @returns {string} hex color
 */
function thresholdColorFor(metricKey, value) {
  return thresholdColor(evaluateThreshold(metricKey, value));
}

// ============================================================
// Chart.js Plugin — Horizontal threshold lines
// ============================================================
// Usage: add to chart config plugins array, pass options.metricKey
//
// Example:
//   plugins: [thresholdLinesPlugin],
//   options: { plugins: { thresholdLines: { metricKey: 'DPCTimePct' } } }
//
var thresholdLinesPlugin = {
  id: 'thresholdLines',

  afterDraw: function(chart, args, options) {
    var metricKey = options && options.metricKey;
    if (!metricKey) return;

    var t = THRESHOLDS[metricKey];
    if (!t) return;

    var ctx = chart.ctx;
    var yAxis = chart.scales.y;
    var chartArea = chart.chartArea;
    if (!yAxis || !chartArea) return;

    var lines = [
      { value: t.warn, color: '#f59e0b', label: 'Warn' },
      { value: t.bad,  color: '#ef4444', label: 'Bad' }
    ];

    ctx.save();

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var yPixel = yAxis.getPixelForValue(line.value);

      // Skip if line is outside visible chart area
      if (yPixel < chartArea.top || yPixel > chartArea.bottom) continue;

      // Draw dashed horizontal line
      ctx.beginPath();
      ctx.setLineDash([6, 4]);
      ctx.strokeStyle = line.color;
      ctx.lineWidth = 1.5;
      ctx.globalAlpha = 0.7;
      ctx.moveTo(chartArea.left, yPixel);
      ctx.lineTo(chartArea.right, yPixel);
      ctx.stroke();

      // Label on right edge
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;
      ctx.fillStyle = line.color;
      ctx.font = '10px sans-serif';
      ctx.textAlign = 'right';
      ctx.textBaseline = 'bottom';
      ctx.fillText(
        line.label + ' (' + line.value + t.unit + ')',
        chartArea.right - 4,
        yPixel - 3
      );
    }

    ctx.restore();
  }
};
