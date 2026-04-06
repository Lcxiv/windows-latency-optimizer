// Advanced Tab — raw data tables

function renderAdvanced(container, pipelineData) {
  if (!pipelineData) {
    container.innerHTML = '<div class="expert-placeholder"><div style="font-size:36px;opacity:0.3;margin-bottom:12px">&#128300;</div>' +
      '<div style="font-size:16px;font-weight:600;margin-bottom:8px">No Pipeline Data</div>' +
      '<div>Run pipeline.ps1 to populate raw ETW, DPC, and ProcMon data</div></div>';
    return;
  }

  let html = '';

  // ETW Provider Events
  if (pipelineData.inputLatency && pipelineData.inputLatency.providerEventCounts) {
    const pec = pipelineData.inputLatency.providerEventCounts;
    html += '<div class="adv-section"><div class="adv-title">ETW PROVIDER EVENTS</div>';
    html += '<table class="adv-table"><thead><tr><th>Provider</th><th>Events</th></tr></thead><tbody>';
    for (const [name, count] of Object.entries(pec)) {
      html += '<tr><td>' + escHtml(name) + '</td><td class="mono">' + count + '</td></tr>';
    }
    html += '</tbody></table></div>';
  }

  // Per-CPU data
  if (pipelineData.cpuData) {
    html += '<div class="adv-section"><div class="adv-title">PER-CPU INTERRUPT / DPC</div>';
    html += '<table class="adv-table"><thead><tr><th>CPU</th><th>Intr %</th><th>DPC %</th><th>Intr/s</th></tr></thead><tbody>';
    pipelineData.cpuData.forEach(cpu => {
      const intP = (cpu.interruptPct || 0).toFixed(3);
      const dpcP = (cpu.dpcPct || 0).toFixed(3);
      const ips = Math.round(cpu.intrPerSec || 0);
      html += '<tr><td>CPU ' + cpu.cpu + '</td><td class="mono">' + intP + '</td><td class="mono">' + dpcP + '</td><td class="mono">' + ips + '</td></tr>';
    });
    html += '</tbody></table></div>';
  }

  // DPC drivers
  if (pipelineData.dpcIsrAnalysis && pipelineData.dpcIsrAnalysis.dpcDrivers) {
    html += '<div class="adv-section"><div class="adv-title">DPC DRIVERS (TOP 10)</div>';
    html += '<table class="adv-table"><thead><tr><th>Module</th><th>Count</th><th>Max &micro;s</th></tr></thead><tbody>';
    pipelineData.dpcIsrAnalysis.dpcDrivers.forEach(d => {
      const name = d.Module || d.module || '?';
      const maxUs = d.MaxUs || d.maxUs || 0;
      const cnt = d.Count || d.count || 0;
      const color = maxUs >= 512 ? 'var(--red)' : maxUs >= 128 ? 'var(--amber)' : 'var(--green)';
      html += '<tr><td style="color:' + color + '">' + escHtml(name) + '</td><td class="mono">' + cnt + '</td><td class="mono" style="color:' + color + '">' + maxUs + '</td></tr>';
    });
    html += '</tbody></table></div>';
  }

  // ProcMon
  if (pipelineData.procmonAnalysis) {
    const pm = pipelineData.procmonAnalysis;
    html += '<div class="adv-section"><div class="adv-title">PROCMON (' + pm.totalEvents + ' events)</div>';
    if (pm.topProcesses && pm.topProcesses.length > 0) {
      html += '<table class="adv-table"><thead><tr><th>Process</th><th>Events</th><th>%</th></tr></thead><tbody>';
      pm.topProcesses.forEach(p => {
        html += '<tr><td>' + escHtml(p.process) + '</td><td class="mono">' + p.count + '</td><td class="mono">' + p.pct + '</td></tr>';
      });
      html += '</tbody></table>';
    }
    if (pm.defenderCount > 0) html += '<div class="adv-note" style="color:var(--amber)">Defender: ' + pm.defenderCount + ' events</div>';
    if (pm.antiCheatCount > 0) html += '<div class="adv-note" style="color:var(--amber)">Anti-cheat: ' + pm.antiCheatCount + ' events</div>';
    html += '</div>';
  }

  container.innerHTML = html || '<div class="expert-placeholder">No advanced data available</div>';
}
