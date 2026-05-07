/* ============================================================
 * Command Center View — Diagnostic dispatch + results display
 * ============================================================ */

function renderCommandView() {
  var el = document.getElementById('commandView');
  if (!el) return;

  var data = window.DIAGNOSE_LATEST || null;
  var html = '';

  /* ── Section 1: Symptom Cards ── */
  html += sectionHeader('Diagnostic Dispatch');
  html += buildSymptomCards(data);

  /* ── Section 2: Last Diagnostic Results ── */
  if (data && data.diagnostics) {
    html += buildDiagnosticResults(data);
  }

  /* ── Section 3: Recommendations ── */
  if (data && data.recommendations && data.recommendations.length > 0) {
    html += buildRecommendations(data.recommendations);
  }

  /* ── Section 4: Quick Actions ── */
  html += buildQuickActions();

  el.innerHTML = html;
}

/* ── Symptom card grid ── */
function buildSymptomCards(data) {
  var domains = [
    {
      id: 'dpc',
      icon: '⌨',
      name: 'Input / DPC',
      symptoms: 'Mouse stutter, HID gaps, polling rate drops, DPC storms',
      cmd: '.\\scripts\\diagnose.ps1 -Domain dpc -MonitorOutput'
    },
    {
      id: 'gpu',
      icon: '💻',
      name: 'GPU / Frames',
      symptoms: 'Frame drops, hitches, clock throttling, G-Sync issues',
      cmd: '.\\scripts\\diagnose.ps1 -Domain gpu -MonitorOutput'
    },
    {
      id: 'net',
      icon: '🌐',
      name: 'Network',
      symptoms: 'Ping spikes, packet loss, DNS lag, TCP tuning',
      cmd: '.\\scripts\\diagnose.ps1 -Domain net -MonitorOutput'
    },
    {
      id: 'system',
      icon: '⚙',
      name: 'System',
      symptoms: 'Full audit, Defender, BIOS drift, services, registry',
      cmd: '.\\scripts\\diagnose.ps1 -Domain system -MonitorOutput'
    },
    {
      id: 'audio',
      icon: '🔊',
      name: 'Audio',
      symptoms: 'Warble, crackle, HDMI dropout, USB DAC glitches',
      cmd: '.\\scripts\\diagnose.ps1 -Domain dpc -Symptom "audio" -MonitorOutput'
    }
  ];

  var html = '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:var(--sp-lg);margin-bottom:var(--sp-xl);">';

  for (var i = 0; i < domains.length; i++) {
    var d = domains[i];
    var badge = '';
    if (data && data.domain === d.id && data.severity) {
      badge = buildSeverityPill(data.severity);
    }

    html += '<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:var(--sp-lg);display:flex;flex-direction:column;gap:var(--sp-sm);">';
    html += '  <div style="display:flex;align-items:center;justify-content:space-between;">';
    html += '    <span style="font-size:var(--text-xl);">' + d.icon + '</span>';
    html += badge;
    html += '  </div>';
    html += '  <div style="font-weight:600;font-size:var(--text-lg);color:var(--text);">' + escHtml(d.name) + '</div>';
    html += '  <div style="font-size:var(--text-sm);color:var(--text-dim);line-height:1.4;">' + escHtml(d.symptoms) + '</div>';
    html += '  <div style="margin-top:auto;padding-top:var(--sp-sm);">';
    html += '    <code style="display:block;background:var(--bg);font-family:var(--font-mono);font-size:var(--text-xs);padding:var(--sp-sm) var(--sp-md);border-radius:4px;color:var(--text-dim);user-select:all;word-break:break-all;">' + escHtml(d.cmd) + '</code>';
    html += '  </div>';
    html += '</div>';
  }

  html += '</div>';

  /* Full diagnostic card */
  html += '<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:var(--sp-lg);margin-bottom:var(--sp-xl);">';
  html += '  <div style="display:flex;align-items:center;gap:var(--sp-sm);margin-bottom:var(--sp-sm);">';
  html += '    <span style="font-size:var(--text-lg);">&#128269;</span>';
  html += '    <span style="font-weight:600;color:var(--text);">Full Diagnostic &mdash; All Domains</span>';
  html += '  </div>';
  html += '  <code style="display:block;background:var(--bg);font-family:var(--font-mono);font-size:var(--text-sm);padding:var(--sp-sm) var(--sp-md);border-radius:4px;color:var(--text-dim);user-select:all;">.\\scripts\\diagnose.ps1 -Domain all -MonitorOutput</code>';
  html += '</div>';

  return html;
}

/* ── Diagnostic results table ── */
function buildDiagnosticResults(data) {
  var html = '';
  var timeLabel = data.timestamp ? cmdRelativeTime(data.timestamp) : '';
  var title = 'Last Diagnostic';
  if (data.domain) title += ' — ' + escHtml(data.domain);
  if (timeLabel) title += ' — ' + escHtml(timeLabel);

  html += sectionHeader(title);

  /* Severity badge */
  if (data.severity) {
    html += '<div style="margin-bottom:var(--sp-lg);">';
    html += buildSeverityBadge(data.severity);
    html += '</div>';
  }

  /* Symptom text */
  if (data.symptomText) {
    html += '<div style="color:var(--text-dim);font-style:italic;margin-bottom:var(--sp-lg);">';
    html += '&ldquo;' + escHtml(data.symptomText) + '&rdquo;';
    html += '</div>';
  }

  /* Diagnostics table */
  var diags = data.diagnostics || [];
  if (diags.length > 0) {
    html += '<div style="overflow-x:auto;">';
    html += '<table class="proc-table" style="width:100%;">';
    html += '<thead><tr>';
    html += '  <th>Script</th>';
    html += '  <th>Status</th>';
    html += '  <th>Duration</th>';
    html += '  <th>Summary</th>';
    html += '</tr></thead>';
    html += '<tbody>';

    for (var i = 0; i < diags.length; i++) {
      var diag = diags[i];
      var statusLabel = cmdStatusLabel(diag);
      var durationText = diag.durationMs != null ? (diag.durationMs / 1000).toFixed(1) + 's' : '--';

      html += '<tr>';
      html += '  <td><span style="font-family:var(--font-mono);font-size:var(--text-sm);">' + escHtml(diag.script || '--') + '</span></td>';
      html += '  <td>' + statusLabel + '</td>';
      html += '  <td style="font-family:var(--font-mono);font-size:var(--text-sm);">' + escHtml(durationText) + '</td>';
      html += '  <td style="color:var(--text-dim);font-size:var(--text-sm);">' + escHtml(diag.summary || '--') + '</td>';
      html += '</tr>';
    }

    html += '</tbody></table>';
    html += '</div>';
  }

  return html;
}

/* ── Recommendations cards ── */
function buildRecommendations(recs) {
  var html = '';
  html += sectionHeader('Recommended Actions');

  for (var i = 0; i < recs.length; i++) {
    var rec = recs[i];
    var priority = rec.priority != null ? rec.priority : i + 1;

    html += '<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:var(--sp-lg);margin-bottom:var(--sp-md);">';
    html += '  <div style="display:flex;align-items:center;gap:var(--sp-sm);margin-bottom:var(--sp-sm);">';
    html += '    <span style="background:var(--data);color:var(--bg);border-radius:12px;padding:2px 10px;font-size:var(--text-xs);font-weight:700;">P' + priority + '</span>';
    html += '  </div>';
    html += '  <div style="color:var(--text);margin-bottom:var(--sp-md);">' + escHtml(rec.action) + '</div>';

    if (rec.agent) {
      html += '  <div style="font-family:var(--font-mono);font-size:var(--text-xs);color:var(--text-dim);margin-bottom:var(--sp-xs);">';
      html += '    Claude Code: <span style="color:var(--data);">' + escHtml(rec.agent) + '</span>';
      html += '  </div>';
    }

    html += '</div>';
  }

  return html;
}

/* ── Quick Actions ── */
function buildQuickActions() {
  var html = '';
  html += sectionHeader('Quick Actions');

  var actions = [
    { label: 'Health Check',  cmd: '.\\scripts\\health-check.ps1' },
    { label: 'Quick Audit',   cmd: '.\\scripts\\audit.ps1 -Mode Quick' },
    { label: 'Full Pipeline', cmd: '.\\scripts\\pipeline.ps1 -SkipWPR -DurationSec 30 -Label DIAG' }
  ];

  html += '<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:var(--sp-lg);">';

  for (var i = 0; i < actions.length; i++) {
    var act = actions[i];
    if (i > 0) {
      html += '<div style="border-top:1px solid var(--border);margin:var(--sp-sm) 0;"></div>';
    }
    html += '<div style="display:flex;align-items:center;gap:var(--sp-lg);padding:var(--sp-xs) 0;">';
    html += '  <span style="color:var(--text);font-weight:500;min-width:110px;font-size:var(--text-sm);">' + escHtml(act.label) + '</span>';
    html += '  <code style="background:var(--bg);font-family:var(--font-mono);font-size:var(--text-xs);padding:var(--sp-xs) var(--sp-md);border-radius:4px;color:var(--text-dim);user-select:all;flex:1;">' + escHtml(act.cmd) + '</code>';
    html += '</div>';
  }

  html += '</div>';
  return html;
}

/* ── Helpers ── */

function cmdRelativeTime(isoString) {
  if (!isoString) return '';
  var now = Date.now();
  var then = new Date(isoString).getTime();
  if (isNaN(then)) return '';
  var diffSec = Math.floor((now - then) / 1000);
  if (diffSec < 0) return 'just now';
  if (diffSec < 60) return diffSec + 's ago';
  if (diffSec < 3600) return Math.floor(diffSec / 60) + ' min ago';
  if (diffSec < 86400) return Math.floor(diffSec / 3600) + 'h ago';
  return new Date(isoString).toLocaleDateString();
}

function cmdStatusLabel(diag) {
  var status = diag.status || 'unknown';
  var exitCode = diag.exitCode;

  if (status === 'completed' && exitCode === 0) {
    return '<span style="color:var(--good);font-weight:600;font-size:var(--text-sm);">&#10003; PASS</span>';
  }
  if (status === 'completed' && exitCode !== 0) {
    return '<span style="color:var(--warn);font-weight:600;font-size:var(--text-sm);">&#9888; WARN</span>';
  }
  if (status === 'error') {
    return '<span style="color:var(--bad);font-weight:600;font-size:var(--text-sm);">&#10007; FAIL</span>';
  }
  if (status === 'skipped') {
    return '<span style="color:var(--muted);font-weight:600;font-size:var(--text-sm);">&#8212; SKIP</span>';
  }
  return '<span style="color:var(--muted);font-size:var(--text-sm);">' + escHtml(status) + '</span>';
}

function buildSeverityPill(severity) {
  var color = 'var(--muted)';
  var bg = 'transparent';
  if (severity === 'HIGH')   { color = 'var(--bad)';  bg = 'var(--bad-bg)';  }
  if (severity === 'MEDIUM') { color = 'var(--warn)'; bg = 'var(--warn-bg)'; }
  if (severity === 'LOW')    { color = 'var(--data)'; bg = 'oklch(0.20 0.03 250)'; }
  if (severity === 'CLEAN')  { color = 'var(--good)'; bg = 'var(--good-bg)'; }
  return '<span style="background:' + bg + ';color:' + color + ';border-radius:12px;padding:2px 8px;font-size:10px;font-weight:600;">' + escHtml(severity) + '</span>';
}

function buildSeverityBadge(severity) {
  var color = 'var(--muted)';
  var bg = 'var(--surface2)';
  var label = severity;
  if (severity === 'HIGH')   { color = 'var(--bad)';  bg = 'var(--bad-bg)';  label = 'HIGH SEVERITY'; }
  if (severity === 'MEDIUM') { color = 'var(--warn)'; bg = 'var(--warn-bg)'; label = 'MEDIUM'; }
  if (severity === 'LOW')    { color = 'var(--data)'; bg = 'oklch(0.20 0.03 250)'; label = 'LOW'; }
  if (severity === 'CLEAN')  { color = 'var(--good)'; bg = 'var(--good-bg)'; label = 'CLEAN'; }
  return '<span style="display:inline-block;background:' + bg + ';color:' + color + ';border-radius:12px;padding:4px 14px;font-size:var(--text-sm);font-weight:700;letter-spacing:0.05em;">' + escHtml(label) + '</span>';
}

window.renderCommandView = renderCommandView;
