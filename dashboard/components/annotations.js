// ============================================================
// ANNOTATIONS — milestone and regression markers for timeline
// Vanilla JS, no modules. Loaded via <script> tag.
// ============================================================
(function() {
  'use strict';

  // Annotation types and their visual config
  var ANNOTATION_TYPES = {
    milestone: { shape: 'diamond', color: '#3b82f6', label: 'Milestone' },
    regression: { shape: 'diamond', color: '#ef4444', label: 'Regression' },
    baseline: { shape: 'circle', color: '#10b981', label: 'Baseline' }
  };

  // Extract annotation data from experiments
  // Experiments with tag 'milestone', 'regression', or 'baseline' get markers
  function getAnnotations(experiments) {
    if (!experiments || !experiments.length) return [];
    var annotations = [];
    for (var i = 0; i < experiments.length; i++) {
      var exp = experiments[i];
      if (!exp.tags || !Array.isArray(exp.tags)) continue;
      for (var j = 0; j < exp.tags.length; j++) {
        var tag = exp.tags[j];
        if (ANNOTATION_TYPES[tag]) {
          annotations.push({
            index: i,
            type: tag,
            label: exp.shortName || exp.name || exp.id,
            date: exp.date,
            config: ANNOTATION_TYPES[tag]
          });
        }
      }
    }
    return annotations;
  }

  // Chart.js plugin: draw annotation markers above data points
  var annotationMarkersPlugin = {
    id: 'annotationMarkers',
    afterDatasetsDraw: function(chart, args, options) {
      if (!options || !options.annotations || !options.annotations.length) return;
      var ctx = chart.ctx;
      var xScale = chart.scales.x;
      var chartArea = chart.chartArea;
      var annotations = options.annotations;

      for (var i = 0; i < annotations.length; i++) {
        var ann = annotations[i];
        var x = xScale.getPixelForValue(ann.index);
        if (x < chartArea.left || x > chartArea.right) continue;

        var y = chartArea.top - 8;
        var size = 5;

        ctx.save();
        ctx.fillStyle = ann.config.color;
        ctx.strokeStyle = ann.config.color;
        ctx.lineWidth = 1.5;

        if (ann.config.shape === 'diamond') {
          ctx.beginPath();
          ctx.moveTo(x, y - size);
          ctx.lineTo(x + size, y);
          ctx.lineTo(x, y + size);
          ctx.lineTo(x - size, y);
          ctx.closePath();
          ctx.fill();
        } else {
          ctx.beginPath();
          ctx.arc(x, y, size - 1, 0, Math.PI * 2);
          ctx.fill();
        }

        // Vertical dashed line from marker to chart area
        ctx.setLineDash([2, 3]);
        ctx.globalAlpha = 0.3;
        ctx.beginPath();
        ctx.moveTo(x, y + size + 2);
        ctx.lineTo(x, chartArea.bottom);
        ctx.stroke();

        ctx.restore();
      }
    }
  };

  // Tooltip extension: show annotation label on hover near markers
  function getAnnotationAtPoint(chart, x, y, annotations) {
    if (!annotations || !annotations.length) return null;
    var xScale = chart.scales.x;
    var chartArea = chart.chartArea;
    var markerY = chartArea.top - 8;

    for (var i = 0; i < annotations.length; i++) {
      var ann = annotations[i];
      var ax = xScale.getPixelForValue(ann.index);
      var dist = Math.sqrt(Math.pow(x - ax, 2) + Math.pow(y - markerY, 2));
      if (dist < 12) return ann;
    }
    return null;
  }

  // Expose globally
  window.Annotations = {
    get: getAnnotations,
    plugin: annotationMarkersPlugin,
    getAtPoint: getAnnotationAtPoint,
    TYPES: ANNOTATION_TYPES
  };
})();
