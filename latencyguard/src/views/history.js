// History Tab — experiment list with selection for comparison

async function renderHistory(container) {
  container.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">Loading experiments...</div>';

  var experiments = await invoke('get_experiments');
  if (!experiments || experiments.length === 0) {
    container.innerHTML = '<div class="expert-placeholder"><div style="font-size:36px;opacity:0.3;margin-bottom:12px">&#128202;</div>' +
      '<div style="font-size:16px;font-weight:600;margin-bottom:8px">No Experiments Yet</div>' +
      '<div>Run pipeline.ps1 to capture experiment data</div></div>';
    return;
  }

  // Store for comparison selection
  state.experiments = experiments;

  var html = '<div class="history-header"><h3>Experiment History (' + experiments.length + ')</h3>';
  html += '<button class="btn-secondary compare-btn" id="compare-btn" onclick="compareExperiments()" disabled>Compare Selected</button>';
  html += '</div>';

  html += '<div class="history-table"><table><thead><tr>';
  html += '<th class="hist-sel">Before</th><th class="hist-sel">After</th>';
  html += '<th>Label</th><th>Date</th><th>DPC %</th><th>Interrupt %</th><th>CPU 0</th>';
  html += '</tr></thead><tbody>';

  experiments.forEach(function(exp, idx) {
    var dpc = exp.cpuTotal ? (exp.cpuTotal.dpcPct || 0).toFixed(3) : '-';
    var intr = exp.cpuTotal ? (exp.cpuTotal.interruptPct || 0).toFixed(3) : '-';
    var cpu0 = exp.interruptTopology ? (exp.interruptTopology.cpu0Share || 0).toFixed(1) + '%' : '-';
    var dpcColor = parseFloat(dpc) > 0.5 ? 'var(--red)' : parseFloat(dpc) > 0.3 ? 'var(--amber)' : 'var(--green)';
    var date = exp.capturedAt ? exp.capturedAt.substring(0, 16).replace('T', ' ') : '-';
    var label = exp.label || '';

    html += '<tr>';
    html += '<td class="hist-sel"><input type="radio" name="cmp-before" value="' + escHtml(label) + '" onchange="updateCompareBtn()"></td>';
    html += '<td class="hist-sel"><input type="radio" name="cmp-after" value="' + escHtml(label) + '" onchange="updateCompareBtn()"></td>';
    html += '<td class="hist-label">' + escHtml(label) + '</td>';
    html += '<td class="hist-date">' + date + '</td>';
    html += '<td style="color:' + dpcColor + '">' + dpc + '%</td>';
    html += '<td>' + intr + '%</td>';
    html += '<td>' + cpu0 + '</td>';
    html += '</tr>';
  });

  html += '</tbody></table></div>';

  // Comparison result container
  html += '<div id="compare-result"></div>';

  container.innerHTML = html;
}

window.updateCompareBtn = function() {
  var before = document.querySelector('input[name="cmp-before"]:checked');
  var after = document.querySelector('input[name="cmp-after"]:checked');
  var btn = document.getElementById('compare-btn');
  if (btn) {
    var ready = before && after && before.value !== after.value;
    btn.disabled = !ready;
  }
};

window.compareExperiments = async function() {
  var before = document.querySelector('input[name="cmp-before"]:checked');
  var after = document.querySelector('input[name="cmp-after"]:checked');
  if (!before || !after || before.value === after.value) return;

  var btn = document.getElementById('compare-btn');
  if (btn) { btn.textContent = 'Comparing...'; btn.disabled = true; }

  try {
    var data = await invoke('compare_experiments', { label1: before.value, label2: after.value });
    if (data) {
      var result = document.getElementById('compare-result');
      if (result) renderComparison(result, data);
    }
  } catch (e) {
    alert('Compare failed: ' + e);
  }

  if (btn) { btn.textContent = 'Compare Selected'; btn.disabled = false; }
};
