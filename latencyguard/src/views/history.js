// History Tab — experiment list with sortable table

async function renderHistory(container) {
  container.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">Loading experiments...</div>';

  const experiments = await invoke('get_experiments');
  if (!experiments || experiments.length === 0) {
    container.innerHTML = '<div class="expert-placeholder"><div style="font-size:36px;opacity:0.3;margin-bottom:12px">&#128202;</div>' +
      '<div style="font-size:16px;font-weight:600;margin-bottom:8px">No Experiments Yet</div>' +
      '<div>Run pipeline.ps1 to capture experiment data</div></div>';
    return;
  }

  let html = '<div class="history-header"><h3>Experiment History (' + experiments.length + ')</h3></div>';
  html += '<div class="history-table"><table><thead><tr>';
  html += '<th>Label</th><th>Date</th><th>DPC %</th><th>Interrupt %</th><th>CPU 0</th>';
  html += '</tr></thead><tbody>';

  experiments.forEach(exp => {
    const dpc = exp.cpuTotal ? (exp.cpuTotal.dpcPct || 0).toFixed(3) : '-';
    const intr = exp.cpuTotal ? (exp.cpuTotal.interruptPct || 0).toFixed(3) : '-';
    const cpu0 = exp.interruptTopology ? (exp.interruptTopology.cpu0Share || 0).toFixed(1) + '%' : '-';
    const dpcColor = parseFloat(dpc) > 0.5 ? 'var(--red)' : parseFloat(dpc) > 0.3 ? 'var(--amber)' : 'var(--green)';
    const date = exp.capturedAt ? exp.capturedAt.substring(0, 16).replace('T', ' ') : '-';

    html += '<tr>';
    html += '<td class="hist-label">' + escHtml(exp.label || '') + '</td>';
    html += '<td class="hist-date">' + date + '</td>';
    html += '<td style="color:' + dpcColor + '">' + dpc + '%</td>';
    html += '<td>' + intr + '%</td>';
    html += '<td>' + cpu0 + '</td>';
    html += '</tr>';
  });

  html += '</tbody></table></div>';
  container.innerHTML = html;
}
