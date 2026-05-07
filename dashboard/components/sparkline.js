// ============================================================
// SPARKLINE COMPONENT — lightweight inline canvas charts
// ============================================================
(function() {
  'use strict';

  var DEFAULTS = {
    width: 64,
    height: 20,
    color: '#3b82f6',
    fillOpacity: 0.2,
    lineWidth: 1.5,
    maxPoints: 12,
    thresholds: null // { warn: number, bad: number } — values above warn are amber, above bad are red
  };

  var THRESHOLD_COLORS = {
    good: '#10b981',
    warn: '#f59e0b',
    bad: '#ef4444'
  };

  var rendered = new Set();
  var tooltipEl = null;

  // ----------------------------------------------------------
  // DATA EXTRACTION
  // ----------------------------------------------------------
  function getSparklineData(metricKey, maxPoints) {
    maxPoints = maxPoints || DEFAULTS.maxPoints;
    var experiments = window.EXPERIMENTS || [];

    var sorted = experiments.slice().sort(function(a, b) {
      return (a.date || '').localeCompare(b.date || '');
    });

    var points = [];
    for (var i = 0; i < sorted.length; i++) {
      var exp = sorted[i];
      var value = extractMetric(exp, metricKey);
      if (value == null) continue;
      points.push({
        value: value,
        date: exp.date || '',
        label: exp.name || exp.label || exp.id
      });
    }

    if (points.length > maxPoints) {
      points = points.slice(points.length - maxPoints);
    }
    return points;
  }

  function extractMetric(exp, key) {
    if (key === 'FPSAvg') {
      return exp.frameTiming && exp.frameTiming.fps ? exp.frameTiming.fps.avg : null;
    }
    if (exp.performance && exp.performance[key]) {
      return exp.performance[key].avg != null ? exp.performance[key].avg : null;
    }
    return null;
  }

  // ----------------------------------------------------------
  // RENDERING
  // ----------------------------------------------------------
  function renderSparkline(containerId, data, options) {
    var container = typeof containerId === 'string'
      ? document.getElementById(containerId)
      : containerId;
    if (!container || !data || data.length === 0) return;

    var opts = {};
    for (var k in DEFAULTS) opts[k] = DEFAULTS[k];
    if (options) { for (var k2 in options) opts[k2] = options[k2]; }

    var canvas = document.createElement('canvas');
    canvas.width = opts.width;
    canvas.height = opts.height;
    canvas.style.display = 'block';
    container.innerHTML = '';
    container.appendChild(canvas);

    var ctx = canvas.getContext('2d');
    ctx.lineWidth = opts.lineWidth;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    var values = data.map(function(d) { return d.value; });
    var min = Math.min.apply(null, values);
    var max = Math.max.apply(null, values);
    var range = max - min;
    var padding = range * 0.1 || 1;
    min -= padding;
    max += padding;

    function xPos(i) { return data.length === 1 ? opts.width / 2 : (i / (data.length - 1)) * opts.width; }
    function yPos(v) { return opts.height - ((v - min) / (max - min)) * opts.height; }

    // Single data point — draw dot
    if (data.length === 1) {
      ctx.beginPath();
      ctx.arc(xPos(0), yPos(data[0].value), 2, 0, Math.PI * 2);
      ctx.fillStyle = getSegmentColor(data[0].value, opts);
      ctx.fill();
      attachSparklineTooltip(canvas, data, opts);
      return;
    }

    // Draw fill
    ctx.beginPath();
    ctx.moveTo(xPos(0), yPos(values[0]));
    for (var i = 1; i < data.length; i++) {
      ctx.lineTo(xPos(i), yPos(values[i]));
    }
    ctx.lineTo(xPos(data.length - 1), opts.height);
    ctx.lineTo(xPos(0), opts.height);
    ctx.closePath();
    ctx.fillStyle = hexToRgba(opts.color, opts.fillOpacity);
    ctx.fill();

    // Draw line (with threshold coloring if enabled)
    if (opts.thresholds) {
      for (var j = 0; j < data.length - 1; j++) {
        ctx.beginPath();
        ctx.moveTo(xPos(j), yPos(values[j]));
        ctx.lineTo(xPos(j + 1), yPos(values[j + 1]));
        ctx.strokeStyle = getSegmentColor(values[j + 1], opts);
        ctx.stroke();
      }
    } else {
      ctx.beginPath();
      ctx.moveTo(xPos(0), yPos(values[0]));
      for (var m = 1; m < data.length; m++) {
        ctx.lineTo(xPos(m), yPos(values[m]));
      }
      ctx.strokeStyle = opts.color;
      ctx.stroke();
    }

    attachSparklineTooltip(canvas, data, opts);
  }

  function getSegmentColor(value, opts) {
    if (!opts.thresholds) return opts.color;
    if (value >= opts.thresholds.bad) return THRESHOLD_COLORS.bad;
    if (value >= opts.thresholds.warn) return THRESHOLD_COLORS.warn;
    return THRESHOLD_COLORS.good;
  }

  function hexToRgba(hex, alpha) {
    var r = parseInt(hex.slice(1, 3), 16);
    var g = parseInt(hex.slice(3, 5), 16);
    var b = parseInt(hex.slice(5, 7), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
  }

  // ----------------------------------------------------------
  // TOOLTIP
  // ----------------------------------------------------------
  function attachSparklineTooltip(canvas, data, opts) {
    if (!tooltipEl) {
      tooltipEl = document.createElement('div');
      tooltipEl.style.cssText = 'position:fixed;z-index:1000;padding:4px 8px;' +
        'background:#1c2840;border:1px solid #1e3a5f;border-radius:4px;' +
        'color:#e2e8f0;font-size:11px;pointer-events:none;white-space:nowrap;display:none;';
      document.body.appendChild(tooltipEl);
    }

    canvas.addEventListener('mousemove', function(e) {
      var rect = canvas.getBoundingClientRect();
      var x = e.clientX - rect.left;
      var idx = Math.round((x / rect.width) * (data.length - 1));
      idx = Math.max(0, Math.min(data.length - 1, idx));
      var point = data[idx];

      tooltipEl.textContent = point.label + ': ' + point.value.toFixed(2);
      tooltipEl.style.display = 'block';

      var tipX = e.clientX + 8;
      var tipY = e.clientY - 28;
      if (tipX + tooltipEl.offsetWidth > window.innerWidth) {
        tipX = e.clientX - tooltipEl.offsetWidth - 8;
      }
      tooltipEl.style.left = tipX + 'px';
      tooltipEl.style.top = tipY + 'px';
    });

    canvas.addEventListener('mouseout', function() {
      if (tooltipEl) tooltipEl.style.display = 'none';
    });
  }

  // ----------------------------------------------------------
  // BATCH INIT WITH INTERSECTION OBSERVER
  // ----------------------------------------------------------
  function initSparklines() {
    var elements = document.querySelectorAll('[data-sparkline]');
    if (!elements.length) return;

    if (!('IntersectionObserver' in window)) {
      // Fallback: render all immediately
      for (var i = 0; i < elements.length; i++) {
        renderFromAttribute(elements[i]);
      }
      return;
    }

    var observer = new IntersectionObserver(function(entries) {
      var toRender = [];
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].isIntersecting) {
          toRender.push(entries[i].target);
          observer.unobserve(entries[i].target);
        }
      }
      if (toRender.length > 0) {
        requestAnimationFrame(function() {
          for (var j = 0; j < toRender.length; j++) {
            renderFromAttribute(toRender[j]);
          }
        });
      }
    }, { rootMargin: '100px' });

    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      var uid = el.id || el.getAttribute('data-sparkline') + '_' + i;
      if (rendered.has(uid)) continue;
      rendered.add(uid);
      observer.observe(el);
    }
  }

  function renderFromAttribute(el) {
    var metricKey = el.getAttribute('data-sparkline');
    var maxPoints = parseInt(el.getAttribute('data-sparkline-points'), 10) || DEFAULTS.maxPoints;
    var thresholdAttr = el.getAttribute('data-sparkline-thresholds');
    var opts = {};

    if (thresholdAttr) {
      try {
        opts.thresholds = JSON.parse(thresholdAttr);
      } catch (e) { /* ignore malformed */ }
    }

    var data = getSparklineData(metricKey, maxPoints);
    if (data.length > 0) {
      renderSparkline(el, data, opts);
    }
  }

  // Reset rendered cache (call when table re-renders)
  function resetSparklines() {
    rendered.clear();
  }

  // ----------------------------------------------------------
  // PUBLIC API
  // ----------------------------------------------------------
  window.Sparkline = {
    render: renderSparkline,
    getData: getSparklineData,
    init: initSparklines,
    reset: resetSparklines
  };
})();
