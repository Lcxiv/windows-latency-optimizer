/* ============================================================
 * Network View — RTT, packet loss, jitter, VoIP readiness
 * Triage verdict: gateway-issue vs wan-issue vs stable
 * ============================================================ */

var _networkDomBuilt = false;

function renderNetworkView() {
  var el = document.getElementById('networkView');
  if (!el) return;

  var snap = window.MONITOR_SNAPSHOT;
  var net  = snap ? snap.network : null;

  if (!net) {
    el.innerHTML =
      '<div class="no-data">' +
      '  <div class="no-data-icon">&#127760;</div>' +
      '  <div class="no-data-text">No network data</div>' +
      '  <div class="no-data-hint">Collector includes network sampling automatically.</div>' +
      '</div>';
    _networkDomBuilt = false;
    return;
  }

  var gw      = net.gateway    || {};
  var targets = net.targets    || [];
  var loss    = net.packetLoss || {};
  var jitter  = net.jitter     || {};
  var verdict = net.verdict    || 'unknown';
  var nicDrop = snap.nicLinkDrop || null;

  /* Best external RTT */
  var bestExtRtt = null;
  var bestExtHost = '--';
  for (var i = 0; i < targets.length; i++) {
    if (targets[i].reachable) {
      if (bestExtRtt === null || targets[i].rttMs < bestExtRtt) {
        bestExtRtt  = targets[i].rttMs;
        bestExtHost = targets[i].host;
      }
    }
  }

  /* VoIP assessment */
  var voipRtt    = bestExtRtt != null ? bestExtRtt : (gw.rttMs || 999);
  var voipLoss   = Math.max(loss.gateway || 0, loss.external || 0);
  var voipJitter = Math.max(jitter.gateway || 0, jitter.external || 0);

  var rttPass    = voipRtt < 150;
  var lossPass   = voipLoss < 1;
  var jitterPass = voipJitter < 30;
  var voipReady  = rttPass && lossPass && jitterPass;

  /* Verdict styling */
  var verdictLabel, verdictColor, verdictBadge;
  if (verdict === 'stable') {
    verdictLabel = 'Network Stable';
    verdictColor = 'green';
    verdictBadge = 'badge-pass';
  } else if (verdict === 'gateway-issue') {
    verdictLabel = 'Gateway Issue (eero)';
    verdictColor = 'red';
    verdictBadge = 'badge-fail';
  } else if (verdict === 'wan-issue') {
    verdictLabel = 'WAN Issue (ISP)';
    verdictColor = 'red';
    verdictBadge = 'badge-fail';
  } else if (verdict === 'no-gateway') {
    verdictLabel = 'No Gateway Found';
    verdictColor = 'amber';
    verdictBadge = 'badge-warn';
  } else {
    verdictLabel = 'Unknown';
    verdictColor = 'amber';
    verdictBadge = 'badge-na';
  }

  var html = '';

  /* ── Alert bar when not stable ── */
  var alertHidden = verdict === 'stable' ? ' hidden' : '';
  html += '<div class="spike-alert-bar' + alertHidden + '">';
  html += '  <span class="spike-alert-icon">&#9888;</span>';
  html += '  <span><strong>' + escHtml(verdictLabel) + '</strong>';
  if (verdict === 'gateway-issue') {
    html += ' — packets lost between PC and router. Check eero health.';
  } else if (verdict === 'wan-issue') {
    html += ' — gateway OK but internet unreachable. ISP or upstream issue.';
  }
  html += '</span></div>';

  /* ── NIC link drop alert ── */
  var nicHidden = nicDrop ? '' : ' hidden';
  html += '<div class="spike-alert-bar' + nicHidden + '" style="border-color:var(--red);background:rgba(255,60,60,0.08);">';
  html += '  <span class="spike-alert-icon">&#9889;</span>';
  html += '  <span><strong>NIC Link Drop Detected</strong>';
  if (nicDrop && nicDrop.timestamp) {
    html += ' — I226-V Event 27 at ' + escHtml(nicDrop.timestamp.replace('T', ' ').substring(0, 19));
  }
  html += '. Check Event Viewer for e2fnexpress events.</span></div>';

  /* ── Summary cards ── */
  html += '<div class="summary-bar">';
  html += summaryCard({
    label: 'Verdict',
    value: verdictLabel,
    unit:  '',
    color: verdictColor,
    badge: verdict.toUpperCase().replace('-', ' '),
    badgeClass: verdictBadge
  });
  html += summaryCard({
    label: 'Gateway RTT',
    value: gw.reachable ? safeNum(gw.rttMs, 0) : 'DOWN',
    unit:  gw.reachable ? 'ms' : '',
    color: !gw.reachable ? 'red' : gw.rttMs < 5 ? 'green' : gw.rttMs < 20 ? 'amber' : 'red',
    sub:   gw.ip || '--'
  });
  html += summaryCard({
    label: 'External RTT',
    value: bestExtRtt != null ? safeNum(bestExtRtt, 0) : 'DOWN',
    unit:  bestExtRtt != null ? 'ms' : '',
    color: bestExtRtt == null ? 'red' : bestExtRtt < 20 ? 'green' : bestExtRtt < 50 ? 'amber' : 'red',
    sub:   bestExtHost
  });
  html += summaryCard({
    label: 'Packet Loss',
    value: safeNum(Math.max(loss.gateway || 0, loss.external || 0), 1),
    unit:  '%',
    color: voipLoss === 0 ? 'green' : voipLoss < 1 ? 'amber' : 'red'
  });
  html += summaryCard({
    label: 'Jitter',
    value: safeNum(voipJitter, 1),
    unit:  'ms',
    color: voipJitter < 5 ? 'green' : voipJitter < 30 ? 'amber' : 'red'
  });
  html += summaryCard({
    label: 'VoIP Ready',
    value: voipReady ? 'PASS' : 'FAIL',
    unit:  '',
    color: voipReady ? 'green' : 'red',
    badge: voipReady ? 'CALLS OK' : 'CALLS AT RISK',
    badgeClass: voipReady ? 'badge-pass' : 'badge-fail'
  });
  html += '</div>';

  /* ── Target detail table ── */
  html += sectionHeader('Ping Targets');
  html += '<div class="proc-table-wrap"><table class="proc-table">';
  html += '<thead><tr><th>Target</th><th>RTT</th><th>Reachable</th></tr></thead><tbody>';

  /* Gateway row */
  html += '<tr>';
  html += '<td><span class="proc-name">' + escHtml(gw.ip || '--') + ' (gateway)</span></td>';
  html += '<td>' + (gw.reachable ? safeNum(gw.rttMs, 1) + ' ms' : '--') + '</td>';
  html += '<td>' + (gw.reachable
    ? '<span class="tag-pill green">YES</span>'
    : '<span class="tag-pill red">NO</span>') + '</td>';
  html += '</tr>';

  /* External rows */
  for (var j = 0; j < targets.length; j++) {
    var t = targets[j];
    html += '<tr>';
    html += '<td><span class="proc-name">' + escHtml(t.host) + '</span></td>';
    html += '<td>' + (t.reachable ? safeNum(t.rttMs, 1) + ' ms' : '--') + '</td>';
    html += '<td>' + (t.reachable
      ? '<span class="tag-pill green">YES</span>'
      : '<span class="tag-pill red">NO</span>') + '</td>';
    html += '</tr>';
  }
  html += '</tbody></table></div>';

  /* ── VoIP checklist ── */
  html += sectionHeader('VoIP Readiness');
  html += '<div class="audit-list">';
  html += _voipCheck('RTT < 150 ms',    'Current: ' + safeNum(voipRtt, 0) + ' ms',    rttPass);
  html += _voipCheck('Packet loss < 1%', 'Current: ' + safeNum(voipLoss, 1) + '%',     lossPass);
  html += _voipCheck('Jitter < 30 ms',   'Current: ' + safeNum(voipJitter, 1) + ' ms', jitterPass);
  html += '</div>';

  /* ── Timeline charts from history ── */
  html += sectionHeader('Network Timeline');
  html += '<div class="charts-grid" style="grid-template-columns:1fr;">';
  html += _chartCardHtml('netCanvasRtt', 'RTT Over Time', 'Gateway (green) vs External (blue) round-trip time');
  html += _chartCardHtml('netCanvasLoss', 'Packet Loss Over Time', 'Rolling loss % — gateway (green) vs external (blue)');
  html += '</div>';

  el.innerHTML = html;
  _networkDomBuilt = true;

  /* ── Build charts from history data ── */
  _buildNetworkCharts();
}

function _voipCheck(label, detail, pass) {
  var cls  = pass ? 'audit-item pass' : 'audit-item fail';
  var icon = pass ? '&#10003;' : '&#10007;';
  var clr  = pass ? 'var(--green)' : 'var(--red)';
  return (
    '<div class="' + cls + '">' +
    '<div class="audit-icon" style="color:' + clr + ';">' + icon + '</div>' +
    '<div class="audit-text">' + escHtml(label) + '</div>' +
    '<div class="audit-detail">' + escHtml(detail) + '</div>' +
    '</div>'
  );
}

function _buildNetworkCharts() {
  var history = window.MONITOR_HISTORY || [];
  var win = history.slice(-300);
  if (win.length === 0) return;

  var labels   = [];
  var gwRtt    = [];
  var extRtt   = [];
  var gwLoss   = [];
  var extLoss  = [];

  for (var i = 0; i < win.length; i++) {
    labels.push(fmtTime(win[i].timestamp));
    var n = win[i].network;
    if (n) {
      gwRtt.push(n.gatewayRtt != null ? n.gatewayRtt : null);
      extRtt.push(n.externalRtt != null ? n.externalRtt : null);
      gwLoss.push(n.gwLoss != null ? n.gwLoss : null);
      extLoss.push(n.extLoss != null ? n.extLoss : null);
    } else {
      gwRtt.push(null);
      extRtt.push(null);
      gwLoss.push(null);
      extLoss.push(null);
    }
  }

  /* RTT chart — dual dataset */
  var rttCtx = document.getElementById('netCanvasRtt');
  if (rttCtx) {
    MonitorCharts.create('netRtt', rttCtx, {
      type: 'line',
      data: {
        labels: labels,
        datasets: [
          {
            label:           'Gateway',
            data:            gwRtt,
            borderColor:     MON_COLORS.green,
            backgroundColor: MON_COLORS.greenA,
            borderWidth:     1.5,
            pointRadius:     0,
            tension:         0.3,
            fill:            false,
            spanGaps:        true
          },
          {
            label:           'External',
            data:            extRtt,
            borderColor:     MON_COLORS.blue,
            backgroundColor: MON_COLORS.blueA,
            borderWidth:     1.5,
            pointRadius:     0,
            tension:         0.3,
            fill:            false,
            spanGaps:        true
          }
        ]
      },
      options: monChartOpts({
        aspectRatio: false,
        scales: {
          x: { ticks: { maxTicksLimit: 10, color: MON_COLORS.muted, font: { size: 9 } } },
          y: { min: 0, suggestedMax: 50, ticks: { color: MON_COLORS.muted, font: { size: 9 } } }
        }
      })
    });
  }

  /* Loss chart — dual dataset */
  var lossCtx = document.getElementById('netCanvasLoss');
  if (lossCtx) {
    MonitorCharts.create('netLoss', lossCtx, {
      type: 'line',
      data: {
        labels: labels,
        datasets: [
          {
            label:           'Gateway Loss %',
            data:            gwLoss,
            borderColor:     MON_COLORS.green,
            backgroundColor: MON_COLORS.greenA,
            borderWidth:     1.5,
            pointRadius:     0,
            tension:         0.3,
            fill:            true,
            spanGaps:        true
          },
          {
            label:           'External Loss %',
            data:            extLoss,
            borderColor:     MON_COLORS.blue,
            backgroundColor: MON_COLORS.blueA,
            borderWidth:     1.5,
            pointRadius:     0,
            tension:         0.3,
            fill:            true,
            spanGaps:        true
          }
        ]
      },
      options: monChartOpts({
        aspectRatio: false,
        scales: {
          x: { ticks: { maxTicksLimit: 10, color: MON_COLORS.muted, font: { size: 9 } } },
          y: { min: 0, max: 100, ticks: { color: MON_COLORS.muted, font: { size: 9 } } }
        }
      })
    });
  }
}

window.renderNetworkView = renderNetworkView;
