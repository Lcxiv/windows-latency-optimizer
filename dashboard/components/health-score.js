// ============================================================
// HEALTH SCORE — Composite score calculator + arc gauge renderer
// ============================================================
// Calculates a 0-100 health score from experiment data across
// multiple dimensions (DPC, interrupt distribution, frame timing,
// page faults, LatencyMon). Renders as a 180-degree arc gauge.
// ============================================================

/**
 * Calculate health score for an experiment.
 * @param {object} exp — experiment object from EXPERIMENTS array
 * @param {object|null} baselineExp — baseline experiment for trend calculation
 * @returns {{ score: number, components: Array, trend: string|null }}
 */
function calculateHealthScore(exp, baselineExp) {
  if (!exp) return { score: 0, components: [], trend: null };

  // Component definitions with weights
  var componentDefs = [
    { key: 'dpc',        label: 'DPC Time',      weight: 0.30 },
    { key: 'interrupt',  label: 'Interrupt Dist', weight: 0.20 },
    { key: 'frametime',  label: 'Frame Timing',   weight: 0.25 },
    { key: 'pagefaults', label: 'Page Faults',    weight: 0.15 },
    { key: 'latencymon', label: 'LatencyMon',     weight: 0.10 }
  ];

  // Calculate raw scores (0-100 each, null if no data)
  var rawScores = {};

  // 1. DPC score — DPC% vs thresholds (lower is better)
  var dpcVal = _perfAvg(exp, 'DPCTimePct');
  if (dpcVal != null) {
    rawScores.dpc = _scoreLinear(dpcVal, 0, 0.5);
  }

  // 2. Interrupt distribution — evenness across CPUs (Gini-like)
  if (exp.cpuData && exp.cpuData.length > 1) {
    rawScores.interrupt = _scoreInterruptDistribution(exp.cpuData);
  }

  // 3. Frame timing — P99 vs 16.67ms (one frame at 60fps)
  if (exp.frameTiming && exp.frameTiming.frameTimeMs && exp.frameTiming.frameTimeMs.p99 != null) {
    rawScores.frametime = _scoreLinear(exp.frameTiming.frameTimeMs.p99, 0, 33.3);
  }

  // 4. Page faults — hard faults/sec vs 50 threshold
  var pageVal = _perfAvg(exp, 'PagesSec');
  if (pageVal != null) {
    rawScores.pagefaults = _scoreLinear(pageVal, 0, 1000);
  }

  // 5. LatencyMon — discrete scoring
  if (exp.latencymon) {
    var result = (exp.latencymon.result || '').toUpperCase();
    if (result === 'PASS') rawScores.latencymon = 100;
    else if (result === 'REVIEW') rawScores.latencymon = 50;
    else rawScores.latencymon = 0;
  }

  // Redistribute weights for null components
  var activeComponents = [];
  var totalWeight = 0;
  for (var i = 0; i < componentDefs.length; i++) {
    var def = componentDefs[i];
    if (rawScores[def.key] != null) {
      activeComponents.push(def);
      totalWeight += def.weight;
    }
  }

  // No data at all — return 0
  if (activeComponents.length === 0) {
    return { score: 0, components: [], trend: null };
  }

  // Calculate weighted score with redistributed weights
  var score = 0;
  var components = [];
  for (var j = 0; j < activeComponents.length; j++) {
    var comp = activeComponents[j];
    var normalizedWeight = comp.weight / totalWeight;
    var compScore = Math.round(rawScores[comp.key]);
    score += compScore * normalizedWeight;
    components.push({
      key: comp.key,
      label: comp.label,
      score: compScore,
      weight: normalizedWeight
    });
  }

  score = Math.round(Math.max(0, Math.min(100, score)));

  // Trend vs baseline
  var trend = null;
  if (baselineExp && baselineExp.id !== exp.id) {
    var baseScore = calculateHealthScore(baselineExp, null).score;
    var delta = score - baseScore;
    if (delta !== 0) {
      trend = (delta > 0 ? '+' : '') + delta;
    }
  }

  return { score: score, components: components, trend: trend };
}

/**
 * Render health score gauge into a container element.
 * Arc gauge: 180 deg sweep, colored by score. Large numeral centered.
 * @param {string} containerId — DOM element ID
 * @param {object} exp — experiment object
 * @param {object|null} baselineExp — for trend calculation
 */
function renderHealthGauge(containerId, exp, baselineExp) {
  var container = document.getElementById(containerId);
  if (!container) return;

  var result = calculateHealthScore(exp, baselineExp);
  var score = result.score;
  var components = result.components;
  var trend = result.trend;

  // Create canvas
  var width = 200;
  var height = 120;
  container.innerHTML = '';
  var canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  container.appendChild(canvas);

  var ctx = canvas.getContext('2d');
  var centerX = width / 2;
  var centerY = height - 10;
  var radius = 70;
  var lineWidth = 14;

  // Background arc (track)
  ctx.beginPath();
  ctx.arc(centerX, centerY, radius, Math.PI, 0, false);
  ctx.strokeStyle = 'rgba(100, 116, 139, 0.2)';
  ctx.lineWidth = lineWidth;
  ctx.lineCap = 'round';
  ctx.stroke();

  // Score arc — colored by score value
  var scoreAngle = Math.PI + (score / 100) * Math.PI;
  var gradient = ctx.createLinearGradient(centerX - radius, centerY, centerX + radius, centerY);
  gradient.addColorStop(0, '#ef4444');
  gradient.addColorStop(0.4, '#f59e0b');
  gradient.addColorStop(0.7, '#10b981');
  gradient.addColorStop(1, '#10b981');

  ctx.beginPath();
  ctx.arc(centerX, centerY, radius, Math.PI, scoreAngle, false);
  ctx.strokeStyle = gradient;
  ctx.lineWidth = lineWidth;
  ctx.lineCap = 'round';
  ctx.stroke();

  // Score numeral
  ctx.fillStyle = _scoreColor(score);
  ctx.font = 'bold 28px system-ui, -apple-system, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(score, centerX, centerY - 30);

  // "/100" label
  ctx.fillStyle = '#64748b';
  ctx.font = '11px system-ui, sans-serif';
  ctx.fillText('/100', centerX, centerY - 10);

  // Trend indicator
  if (trend) {
    var trendColor = trend.charAt(0) === '+' ? '#10b981' : '#ef4444';
    ctx.fillStyle = trendColor;
    ctx.font = '12px system-ui, sans-serif';
    ctx.textAlign = 'center';
    var arrow = trend.charAt(0) === '+' ? '▲' : '▼';
    ctx.fillText(arrow + ' ' + trend, centerX, centerY + 6);
  }

  // Component breakdown bars below canvas
  if (components.length > 0) {
    var breakdown = document.createElement('div');
    breakdown.style.cssText = 'display:flex;gap:4px;justify-content:center;margin-top:6px;flex-wrap:wrap;';
    for (var k = 0; k < components.length; k++) {
      var c = components[k];
      var pill = document.createElement('span');
      pill.style.cssText = 'font-size:10px;padding:2px 6px;border-radius:4px;background:rgba(30,58,95,0.5);color:' + _scoreColor(c.score) + ';';
      pill.textContent = c.label + ' ' + c.score;
      breakdown.appendChild(pill);
    }
    container.appendChild(breakdown);
  }
}

/**
 * Render compact inline score (for table header area).
 * Just the number + color + trend arrow, no gauge.
 * @param {string} containerId — DOM element ID
 * @param {object} exp — experiment object
 * @param {object|null} baselineExp — for trend calculation
 */
function renderInlineScore(containerId, exp, baselineExp) {
  var container = document.getElementById(containerId);
  if (!container) return;

  var result = calculateHealthScore(exp, baselineExp);
  var score = result.score;
  var trend = result.trend;

  var html = '<span style="font-weight:700;font-size:14px;color:' + _scoreColor(score) + '">' + score + '</span>';

  if (trend) {
    var trendColor = trend.charAt(0) === '+' ? '#10b981' : '#ef4444';
    var arrow = trend.charAt(0) === '+' ? '▲' : '▼';
    html += ' <span style="font-size:11px;color:' + trendColor + '">' + arrow + trend + '</span>';
  }

  container.innerHTML = html;
}

// ============================================================
// INTERNAL HELPERS
// ============================================================

/**
 * Get average value from experiment performance data.
 * @private
 */
function _perfAvg(exp, key) {
  if (!exp.performance) return null;
  var metric = exp.performance[key];
  if (!metric || metric.avg == null) return null;
  return metric.avg;
}

/**
 * Linear scoring: value of 0 = 100 points, value >= max = 0 points.
 * @private
 */
function _scoreLinear(value, min, max) {
  if (value <= min) return 100;
  if (value >= max) return 0;
  return 100 * (1 - (value - min) / (max - min));
}

/**
 * Score interrupt distribution evenness.
 * Perfect evenness (all CPUs equal) = 100.
 * All load on one CPU = 0.
 * Uses coefficient of variation of DPC%.
 * @private
 */
function _scoreInterruptDistribution(cpuData) {
  var values = [];
  for (var i = 0; i < cpuData.length; i++) {
    values.push(cpuData[i].dpcPct || 0);
  }

  var n = values.length;
  if (n === 0) return null;

  // Mean
  var sum = 0;
  for (var j = 0; j < n; j++) sum += values[j];
  var mean = sum / n;

  // If mean is effectively zero, distribution is ideal (no DPC load)
  if (mean < 0.001) return 100;

  // Std deviation
  var sqSum = 0;
  for (var k = 0; k < n; k++) {
    var diff = values[k] - mean;
    sqSum += diff * diff;
  }
  var std = Math.sqrt(sqSum / n);

  // Coefficient of variation (0 = perfectly even, higher = worse)
  var cv = std / mean;

  // Map CV to score: CV=0 -> 100, CV>=3 -> 0
  return Math.max(0, Math.min(100, 100 * (1 - cv / 3)));
}

/**
 * Get color for a score value.
 * @private
 */
function _scoreColor(score) {
  if (score >= 80) return '#10b981';
  if (score >= 50) return '#f59e0b';
  return '#ef4444';
}
