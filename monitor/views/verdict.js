/* Verdict View — the "what killed my PC" incident timeline.
 * Reads window.EVIDENCE_LATEST (written by scripts\evidence_correlate.ps1).
 * file:// compatible: no fetch, consumes a window.* data object like the others.
 */
(function () {
  'use strict';

  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  var KIND_COLOR = { observed: '#69f0ae', inferred: '#4dd0e1', absent: '#ff5252' };
  var SEV_COLOR  = { info: '#6b7a8e', warn: '#c49a2c', error: '#c75a5a', critical: '#ff5252' };

  function chip(text, color) {
    return '<span style="font-family:monospace;font-size:.7rem;padding:.12rem .45rem;border-radius:4px;'
         + 'background:rgba(255,255,255,.04);border:1px solid ' + color + ';color:' + color + '">'
         + esc(text) + '</span>';
  }

  function render(container) {
    var d = window.EVIDENCE_LATEST || null;
    if (!d || !d.rows || !d.rows.length) {
      container.innerHTML = '<div class="empty-state">'
        + 'No evidence timeline yet.<br><br>'
        + 'Run <code>scripts\\evidence_correlate.ps1</code> to generate '
        + '<code>monitor\\data\\evidence_latest.js</code>, '
        + 'then <code>scripts\\evidence_postmortem.ps1</code> to decode any dumps.'
        + '</div>';
      return;
    }

    var html = '';

    // ── headline verdict: the recurrence leader ──
    var lead = (d.recurrence && d.recurrence.length) ? d.recurrence[0] : null;
    html += '<div style="margin:0 0 1.1rem">';
    if (lead) {
      html += '<div style="font-family:monospace;font-size:.72rem;letter-spacing:.2em;'
            + 'text-transform:uppercase;color:#5ba8c4;margin-bottom:.4rem">Leading recurring fault</div>';
      html += '<div style="font-size:1.5rem;font-weight:700;color:#e3e7ed">'
            + esc(lead.module) + ' <span style="color:#c75a5a">&times;' + lead.count + '</span>'
            + ' <span style="font-size:.9rem;color:#6b7a8e;font-weight:400">DPC-watchdog incidents</span></div>';
    } else {
      html += '<div style="font-size:1.2rem;color:#6b7a8e">No recurring bugcheck attribution yet — '
            + 'run the post-mortem producer over your dumps.</div>';
    }
    html += '<div style="font-family:monospace;font-size:.7rem;color:#6b7a8e;margin-top:.4rem">'
          + esc(d.rows.length) + ' evidence rows &middot; generated ' + esc(d.generated || '') + '</div>';
    html += '</div>';

    // ── misdirection table: symptom != cause ──
    if (d.misdirection && d.misdirection.length) {
      html += '<div class="card" style="margin-bottom:1rem">';
      html += '<h3 style="margin-bottom:.5rem">Symptom &ne; cause</h3>';
      html += '<table style="width:100%;border-collapse:collapse;font-size:.9rem">';
      html += '<tr style="color:#6b7a8e;font-family:monospace;font-size:.7rem">'
            + '<td style="padding:.3rem .5rem">FELT</td><td>ACTUAL</td><td>CONF</td></tr>';
      for (var i = 0; i < d.misdirection.length; i++) {
        var m = d.misdirection[i];
        html += '<tr style="border-top:1px solid #1d2733">'
              + '<td style="padding:.35rem .5rem;color:#c75a5a">' + esc(m.felt) + '</td>'
              + '<td style="color:#69f0ae">' + esc(m.truth) + '</td>'
              + '<td style="font-family:monospace;color:#8b98a8">' + esc(m.confidence) + '</td></tr>';
      }
      html += '</table></div>';
    }

    // ── incident groups: each incident, its evidence chain ──
    html += '<div style="font-family:monospace;font-size:.72rem;letter-spacing:.2em;'
          + 'text-transform:uppercase;color:#5ba8c4;margin:.6rem 0 .5rem">Incident timeline</div>';

    var groups = d.incidents || [];
    for (var g = 0; g < groups.length; g++) {
      var inc = groups[g];
      html += '<div class="card" style="margin-bottom:.7rem">';
      html += '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.5rem">';
      html += '<span style="font-weight:600;color:#e3e7ed">' + esc(inc.id) + '</span>';
      html += '<span style="font-family:monospace;font-size:.72rem;color:#6b7a8e">'
            + esc(inc.rows.length) + ' rows</span>';
      html += '</div>';

      for (var r = 0; r < inc.rows.length; r++) {
        var row = inc.rows[r];
        var kc = KIND_COLOR[row.evidence_kind] || '#6b7a8e';
        var sc = SEV_COLOR[row.severity] || '#6b7a8e';
        html += '<div style="display:flex;gap:.5rem;align-items:baseline;padding:.25rem 0;'
              + 'border-top:1px solid #11171f;font-size:.85rem">';
        html += '<span style="font-family:monospace;font-size:.72rem;color:#5a6675;min-width:9ch">'
              + esc((row.ts || '').replace('T', ' ').slice(5, 16)) + '</span>';
        html += chip(row.signal, sc);
        html += '<span style="color:#8b98a8">' + esc(row.subsystem);
        if (row.cpu === 0) html += ' <span style="color:#ff5252">CPU0</span>';
        if (row.faulting_module) html += ' &rarr; <span style="color:#e3e7ed">' + esc(row.faulting_module) + '</span>';
        html += '</span>';
        html += '<span style="margin-left:auto">' + chip(row.evidence_kind, kc) + '</span>';
        html += '</div>';
      }
      html += '</div>';
    }

    container.innerHTML = html;
  }

  // Codebase pattern: expose a global renderXView() that finds its own container.
  window.renderVerdictView = function () {
    var el = document.getElementById('verdictView');
    if (el) render(el);
  };
})();
