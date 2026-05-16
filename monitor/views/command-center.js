/* ============================================================
 * Command Center View — Diagnostic dispatch + results display
 * Craft: anti-ai-slop (SVG icons, no emoji), state-coverage
 *        (empty/populated), laws-of-ux (proximity, Hick's, Von Restorff)
 * Globals: escHtml, sectionHeader, summaryCard, safeNum
 * ============================================================ */

/* ── Monoline SVG icons (1.7px stroke, currentColor) ── */
var CMD_ICONS = {
  dpc:      '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="6"/><line x1="12" y1="2" x2="12" y2="10"/></svg>',
  gpu:      '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>',
  net:      '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M2 12h20"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>',
  system:   '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg>',
  audio:    '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/></svg>',
  search:   '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>',
  terminal: '<svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>'
};

function renderCommandView() {
  var el = document.getElementById('commandView');
  if (!el) return;

  var data = window.DIAGNOSE_LATEST || null;
  var hasResults = data && data.diagnostics && data.diagnostics.length > 0;
  var html = '';

  /* ── Empty state (first-use onboarding) ── */
  if (!hasResults) {
    html += buildCmdEmptyState();
  }

  /* ── Domain dispatch grid ── */
  html += sectionHeader('Diagnostic Dispatch');
  html += buildDomainGrid(data);
  html += buildFullDiagBanner();

  /* ── KPI + Results (populated state) ── */
  if (hasResults) {
    html += buildCmdKpiBar(data);
    html += buildCmdResultsTable(data);
  }

  /* ── Recommendations ── */
  if (data && data.recommendations && data.recommendations.length > 0) {
    html += buildCmdRecommendations(data.recommendations);
  }

  /* ── Quick Actions ── */
  html += buildCmdQuickActions();

  el.innerHTML = html;
}

/* ── Empty state: first-use onboarding ── */
function buildCmdEmptyState() {
  var html = '';
  html += '<div class="cmd-empty">';
  html += '  <div class="cmd-empty-icon">' + CMD_ICONS.terminal + '</div>';
  html += '  <div class="cmd-empty-title">No diagnostics yet</div>';
  html += '  <div class="cmd-empty-desc">';
  html += '    Run a diagnostic to see results, recommendations, and quick actions.';
  html += '    Pick a domain below for targeted analysis, or run the full suite.';
  html += '  </div>';
  html += '  <code class="cmd-empty-cmd">.\\scripts\\diagnose.ps1 -Interactive</code>';
  html += '  <div class="cmd-empty-hint">Requires elevated PowerShell</div>';
  html += '</div>';
  return html;
}

/* ── Domain dispatch cards ── */
function buildDomainGrid(data) {
  var domains = [
    { id: 'dpc',    name: 'Input / DPC',  desc: 'Mouse stutter, HID gaps, polling rate, DPC storms',  cmd: '.\\scripts\\diagnose.ps1 -Domain dpc -MonitorOutput' },
    { id: 'gpu',    name: 'GPU / Frames',  desc: 'Frame drops, hitches, clock throttling, G-Sync',     cmd: '.\\scripts\\diagnose.ps1 -Domain gpu -MonitorOutput' },
    { id: 'net',    name: 'Network',       desc: 'Ping spikes, packet loss, DNS lag, TCP tuning',      cmd: '.\\scripts\\diagnose.ps1 -Domain net -MonitorOutput' },
    { id: 'system', name: 'System',        desc: 'Full audit, Defender, BIOS, services, registry',     cmd: '.\\scripts\\diagnose.ps1 -Domain system -MonitorOutput' },
    { id: 'audio',  name: 'Audio',         desc: 'Warble, crackle, HDMI dropout, USB DAC glitches',    cmd: '.\\scripts\\diagnose.ps1 -Domain dpc -Symptom "audio" -MonitorOutput' }
  ];

  var html = '<div class="cmd-grid">';

  for (var i = 0; i < domains.length; i++) {
    var d = domains[i];
    var isActive = data && data.domain === d.id;
    var cardClass = 'cmd-card' + (isActive ? ' active' : '');

    var badge = '';
    if (isActive && data.severity) {
      badge = buildCmdSeverityPill(data.severity);
    }

    html += '<div class="' + cardClass + '">';
    html += '  <div class="cmd-card-head">';
    html += '    <span class="cmd-card-icon ' + d.id + '">' + (CMD_ICONS[d.id] || '') + '</span>';
    html += '    ' + badge;
    html += '  </div>';
    html += '  <div class="cmd-card-name">' + escHtml(d.name) + '</div>';
    html += '  <div class="cmd-card-desc">' + escHtml(d.desc) + '</div>';
    html += '  <code class="cmd-card-cmd">' + escHtml(d.cmd) + '</code>';
    html += '</div>';
  }

  html += '</div>';
  return html;
}

/* ── Full diagnostic banner ── */
function buildFullDiagBanner() {
  var html = '';
  html += '<div class="cmd-full-banner">';
  html += '  <span class="cmd-full-banner-icon">' + CMD_ICONS.search + '</span>';
  html += '  <div class="cmd-full-banner-text">';
  html += '    <span class="cmd-full-banner-label">Full Diagnostic &mdash; All Domains</span>';
  html += '    <code class="cmd-full-banner-cmd">.\\scripts\\diagnose.ps1 -Domain all -MonitorOutput</code>';
  html += '  </div>';
  html += '</div>';
  return html;
}

/* ── KPI summary bar (populated state) ── */
function buildCmdKpiBar(data) {
  var diags = data.diagnostics || [];
  var passCount = 0;
  var warnCount = 0;
  var failCount = 0;
  var totalMs = 0;

  for (var i = 0; i < diags.length; i++) {
    var d = diags[i];
    if (d.status === 'completed' && d.exitCode === 0) passCount++;
    else if (d.status === 'completed') warnCount++;
    else if (d.status === 'error') failCount++;
    if (d.durationMs != null) totalMs += d.durationMs;
  }

  var sevColor = 'blue';
  if (data.severity === 'HIGH') sevColor = 'red';
  else if (data.severity === 'MEDIUM') sevColor = 'amber';
  else if (data.severity === 'CLEAN') sevColor = 'green';

  var html = '<div class="summary-bar">';
  html += summaryCard({
    label: 'Severity',
    value: data.severity || '--',
    unit: '',
    color: sevColor,
    badge: data.domain ? data.domain.toUpperCase() : null,
    badgeClass: 'badge-na'
  });
  html += summaryCard({
    label: 'Scripts',
    value: diags.length,
    unit: 'run',
    color: 'blue'
  });
  html += summaryCard({
    label: 'Passed',
    value: passCount,
    unit: '',
    color: passCount === diags.length ? 'green' : 'blue'
  });
  if (warnCount > 0) {
    html += summaryCard({
      label: 'Warnings',
      value: warnCount,
      unit: '',
      color: 'amber'
    });
  }
  if (failCount > 0) {
    html += summaryCard({
      label: 'Failed',
      value: failCount,
      unit: '',
      color: 'red',
      badge: 'ACTION',
      badgeClass: 'badge-fail'
    });
  }
  html += summaryCard({
    label: 'Duration',
    value: totalMs > 0 ? (totalMs / 1000).toFixed(1) : '--',
    unit: totalMs > 0 ? 's' : '',
    color: 'blue'
  });
  html += '</div>';
  return html;
}

/* ── Results table ── */
function buildCmdResultsTable(data) {
  var html = '';
  var timeLabel = data.timestamp ? cmdRelativeTime(data.timestamp) : '';
  var badgeText = '';
  if (data.domain) badgeText += data.domain;
  if (timeLabel) badgeText += (badgeText ? ' · ' : '') + timeLabel;

  html += sectionHeader('Results', badgeText || null);

  /* Symptom quote */
  if (data.symptomText) {
    html += '<div class="cmd-symptom-quote">';
    html += '&ldquo;' + escHtml(data.symptomText) + '&rdquo;';
    html += '</div>';
  }

  /* Diagnostics table */
  var diags = data.diagnostics || [];
  if (diags.length > 0) {
    html += '<div class="proc-table-wrap">';
    html += '<table class="proc-table">';
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
      var dur = diag.durationMs != null ? (diag.durationMs / 1000).toFixed(1) + 's' : '--';

      html += '<tr>';
      html += '  <td><span class="proc-name">' + escHtml(diag.script || '--') + '</span></td>';
      html += '  <td>' + statusLabel + '</td>';
      html += '  <td class="mono">' + escHtml(dur) + '</td>';
      html += '  <td style="color:var(--text-dim);">' + escHtml(diag.summary || '--') + '</td>';
      html += '</tr>';
    }

    html += '</tbody></table>';
    html += '</div>';
  }

  return html;
}

/* ── Recommendations ── */
function buildCmdRecommendations(recs) {
  var html = '';
  html += sectionHeader('Recommended Actions', recs.length + ' item' + (recs.length !== 1 ? 's' : ''));

  for (var i = 0; i < recs.length; i++) {
    var rec = recs[i];
    var priority = rec.priority != null ? rec.priority : i + 1;

    html += '<div class="cmd-rec">';
    html += '  <div class="cmd-rec-num">' + priority + '</div>';
    html += '  <div class="cmd-rec-body">';
    html += '    <div class="cmd-rec-action">' + escHtml(rec.action) + '</div>';
    if (rec.agent) {
      html += '    <div class="cmd-rec-agent">Claude Code: <span>' + escHtml(rec.agent) + '</span></div>';
    }
    html += '  </div>';
    html += '</div>';
  }

  return html;
}

/* ── Quick Actions ── */
function buildCmdQuickActions() {
  var html = '';
  html += sectionHeader('Quick Actions');

  var actions = [
    { label: 'Health Check',  cmd: '.\\scripts\\health-check.ps1' },
    { label: 'Quick Audit',   cmd: '.\\scripts\\audit.ps1 -Mode Quick' },
    { label: 'Full Pipeline', cmd: '.\\scripts\\pipeline.ps1 -SkipWPR -DurationSec 30 -Label DIAG' }
  ];

  html += '<div class="cmd-quick">';
  for (var i = 0; i < actions.length; i++) {
    var act = actions[i];
    html += '<div class="cmd-quick-row">';
    html += '  <span class="cmd-quick-label">' + escHtml(act.label) + '</span>';
    html += '  <code class="cmd-quick-cmd">' + escHtml(act.cmd) + '</code>';
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
    return '<span class="tag-pill green">PASS</span>';
  }
  if (status === 'completed' && exitCode !== 0) {
    return '<span class="tag-pill amber">WARN</span>';
  }
  if (status === 'error') {
    return '<span class="tag-pill red">FAIL</span>';
  }
  if (status === 'skipped') {
    return '<span class="tag-pill" style="background:var(--surface2);color:var(--muted);">SKIP</span>';
  }
  return '<span class="color-muted">' + escHtml(status) + '</span>';
}

function buildCmdSeverityPill(severity) {
  var cls = '';
  if (severity === 'HIGH') cls = 'red';
  else if (severity === 'MEDIUM') cls = 'amber';
  else if (severity === 'LOW') cls = 'blue';
  else if (severity === 'CLEAN') cls = 'green';
  if (cls) return '<span class="tag-pill ' + cls + '">' + escHtml(severity) + '</span>';
  return '<span class="tag-pill">' + escHtml(severity) + '</span>';
}

window.renderCommandView = renderCommandView;
