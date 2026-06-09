/* LatencyGuard — Flight Recorder UI
 * Vanilla JS, classic script, file:// compatible.
 * No fetch, no ES modules, no pushState. Hash routing only.
 * Reads window.MONITOR_SNAPSHOT / MONITOR_HISTORY / EVIDENCE_LATEST.
 * Live snapshot refreshes via dynamic <script> reload + ?t= cache-bust (the
 * same trick monitor.js uses). Every global read is undefined-guarded so a
 * missing data file degrades to an empty-state, never a crash.
 */
(function () {
  'use strict';

  var REFRESH_INTERVAL_MS = 2000;   // matches collector 2s write cadence
  var STALE_THRESHOLD_MS = 10000;   // snapshot older than this => collector dead
  var SPARK_N = 48;                 // rolling DPC sparkline buffer length
  // Motion reduction is handled in CSS (@media prefers-reduced-motion): the
  // pulse + meter transitions are disabled there. The sparkline reflects real
  // telemetry (informational, not decorative motion), so it always renders.

  /* ------------------------------------------------------------------ */
  /* tiny helpers                                                        */
  /* ------------------------------------------------------------------ */
  function $(id) { return document.getElementById(id); }
  function txt(id, v) { var el = $(id); if (el) el.textContent = v; }
  function html(id, v) { var el = $(id); if (el) el.innerHTML = v; }
  function num(v) { return (typeof v === 'number' && isFinite(v)) ? v : null; }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
  function fixed(v, d) { var n = num(v); return n == null ? '—' : n.toFixed(d); }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
  function pad2(n) { return (n < 10 ? '0' : '') + n; }

  /* Parse the three ISO timestamp forms the bus emits (Z-UTC, ±offset,
   * with/without fractional seconds). Date handles all three; guard NaN. */
  function parseTs(s) {
    if (!s) return null;
    var d = new Date(s);
    return isNaN(d.getTime()) ? null : d;
  }
  var MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  function fmtDayTime(s) {
    var d = parseTs(s); if (!d) return '—';
    return MONTHS[d.getMonth()] + ' ' + d.getDate() + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  }
  function fmtDay(s) {
    var d = parseTs(s); if (!d) return '—';
    return MONTHS[d.getMonth()] + ' ' + d.getDate();
  }
  function fmtClock(secs) {
    if (secs == null || !isFinite(secs) || secs < 0) return '--:--:--';
    var h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60), s = Math.floor(secs % 60);
    return pad2(h) + ':' + pad2(m) + ':' + pad2(s);
  }

  /* ------------------------------------------------------------------ */
  /* global accessors (always guarded)                                  */
  /* ------------------------------------------------------------------ */
  function snap() { return (typeof window.MONITOR_SNAPSHOT === 'object' && window.MONITOR_SNAPSHOT) || null; }
  function hist() { return (Object.prototype.toString.call(window.MONITOR_HISTORY) === '[object Array]') ? window.MONITOR_HISTORY : []; }
  function evid() { return (typeof window.EVIDENCE_LATEST === 'object' && window.EVIDENCE_LATEST) || null; }

  /* ------------------------------------------------------------------ */
  /* live state                                                          */
  /* ------------------------------------------------------------------ */
  var State = {
    view: 'overview',
    alive: false,
    lastCheck: 0,        // seconds since last successful snapshot apply
    bootTs: null,        // first snapshot timestamp we saw (uptime anchor)
    dpcBuf: [],          // rolling DPC% values for the sparkline
    builtStatic: false   // evidence-derived panes built once
  };

  /* ================================================================== */
  /* ROUTING — hash only                                                */
  /* ================================================================== */
  var VIEWS = ['overview', 'incidents', 'history', 'gpu', 'network', 'settings'];
  var CRUMBS = {
    overview: 'Overview', incidents: 'Incidents', history: 'History',
    gpu: 'GPU & Display', network: 'Network', settings: 'Settings'
  };
  var tabs = [].slice.call(document.querySelectorAll('.nav button'));

  function applyView(v) {
    if (VIEWS.indexOf(v) === -1) v = 'overview';
    State.view = v;
    tabs.forEach(function (b) {
      var on = b.dataset.v === v;
      b.setAttribute('aria-selected', on ? 'true' : 'false');
      b.tabIndex = on ? 0 : -1;
    });
    document.querySelectorAll('main > section').forEach(function (s) {
      s.classList.toggle('hidden', s.id !== v);
    });
    txt('crumb', '— ' + (CRUMBS[v] || 'Overview'));
    var main = document.querySelector('.main'); if (main) main.scrollTop = 0;
  }
  function handleRoute() {
    var h = location.hash.replace('#', '') || 'overview';
    applyView(h);
  }
  function navigateTo(h) { location.hash = h; } // fires hashchange -> handleRoute

  tabs.forEach(function (b) {
    b.addEventListener('click', function () { navigateTo(b.dataset.v); });
    b.addEventListener('keydown', function (e) {
      var i = tabs.indexOf(b), n;
      if (e.key === 'ArrowDown' || e.key === 'ArrowRight') { e.preventDefault(); n = tabs[(i + 1) % tabs.length]; n.focus(); }
      if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') { e.preventDefault(); n = tabs[(i - 1 + tabs.length) % tabs.length]; n.focus(); }
    });
  });
  window.addEventListener('hashchange', handleRoute);

  /* ================================================================== */
  /* EVIDENCE → VERDICT / FACTS / CHAIN / INCIDENTS / SXC                */
  /* ================================================================== */

  // Human labels + descriptions for evidence signals (the design's
  // "human label + mono code" + "what happened" columns).
  var SIGNAL = {
    log_silence:           { h: 'Blackout',    d: 'Monitoring went dark — a telling gap before the hang' },
    dpc_watchdog:          { h: 'GPU stall',   d: 'The graphics driver <b>{mod}</b> stopped responding' },
    dpc_watchdog_hang:     { h: 'GPU stall',   d: 'The graphics driver <b>{mod}</b> locked up the system' },
    dirty_shutdown:        { h: 'Hard crash',  d: 'System went down hard, with no clean exit' },
    unexpected_shutdown:   { h: 'Hard crash',  d: 'System shut down unexpectedly, no clean exit' },
    bugcheck:              { h: 'Confirmed',   d: 'Crash dump decoded → <b>{mod}</b> is the faulting module' },
    tdr:                   { h: 'Display reset', d: 'GPU timed out and was reset (<b>{mod}</b> TDR)' },
    regression:            { h: 'Regression',  d: 'The same fault pattern resurfaced (<b>{mod}</b>)' },
    near_miss:             { h: 'Near miss',   d: 'A stall almost crossed the watchdog threshold' },
    driver_uninstall:      { h: 'Driver removed', d: 'The corrupted GPU driver was uninstalled' },
    misdiagnosis_correction:{ h: 'Re-diagnosed', d: 'Earlier read corrected — the real cause was elsewhere' },
    user_reported_symptom: { h: 'You reported', d: 'A symptom was logged from the {sub} subsystem' },
    cpu0_dpc_pct:          { h: 'CPU 0 spike', d: 'CPU 0 overloaded with deferred driver work' },
    cpu_dpc_high:          { h: 'CPU spike',  d: 'A core crossed the high-DPC threshold' },
    ping_rtt:              { h: 'Latency probe', d: 'Round-trip latency sampled — network was clean' },
    total_dpc_pct:         { h: 'DPC sample',  d: 'Total DPC time sampled across all cores' },
    network_verdict:       { h: 'Network read', d: 'Network health re-evaluated this cycle' },
    baseline_quiet:        { h: 'Baseline',    d: 'No anomaly this cycle — a quiet baseline' },
    display_reset:         { h: 'Display',     d: 'No display-pipeline reset detected' },
    dwm_crash:             { h: 'Compositor',  d: 'No desktop compositor crash detected' }
  };
  var SUBSYS_LABEL = {
    gpu: 'GPU', cpu_dpc: 'CPU / DPC', network: 'network', input: 'input',
    power: 'power', display: 'display', system: 'system'
  };
  var FELT_LABEL = {
    input: 'A mouse-input stutter', network: 'A network lag spike',
    gpu: 'A GPU glitch', cpu_dpc: 'A random freeze', power: 'A hard freeze',
    display: 'A display glitch', system: 'A system hang'
  };
  var TRUTH_LABEL = {
    gpu: 'The GPU driver stalling', cpu_dpc: 'CPU 0 buried in driver work',
    network: 'A network fault', input: 'An input-stack fault',
    power: 'A power-state fault', display: 'A display-pipeline fault',
    system: 'A system-level fault'
  };

  function signalInfo(row) {
    var s = SIGNAL[row.signal] || { h: row.signal, d: row.signal };
    var mod = (row.faulting_module && row.faulting_module.length) ? row.faulting_module : 'the driver';
    var sub = SUBSYS_LABEL[row.subsystem] || row.subsystem || 'system';
    var d = s.d.replace('{mod}', esc(mod)).replace('{sub}', esc(sub));
    return { h: s.h, d: d };
  }

  // Pick the most severe incident with a faulting module as the headline case.
  var SEV_RANK = { critical: 4, error: 3, warn: 2, info: 1 };

  function buildVerdict() {
    var ev = evid();
    var sev = $('ov-sev');

    if (!ev) {
      // graceful empty-state: no correlator output on disk
      if (sev) sev.className = 'sev warn';
      txt('ov-sev-t', 'No evidence yet');
      txt('ov-verdict', 'The recorder has no correlated evidence to show');
      txt('ov-felt', '—'); txt('ov-was', '—');
      txt('ov-lede', 'Run the evidence correlator to populate the verdict, or wait for the next recorder cycle.');
      txt('ov-window', '—'); txt('ov-module', '—'); txt('ov-hits', '—'); txt('ov-conf', '—');
      txt('ov-meta', 'case —');
      txt('ev-summary', '0 signals · 0 incidents');
      html('ev-rows', '<div class="ev-none">No evidence rows on record.</div>');
      var ct0 = $('nav-inc-ct'); if (ct0) { ct0.textContent = '0'; ct0.className = 'ct none'; }
      return;
    }

    var rows = (ev.rows && ev.rows.length) ? ev.rows : [];
    var incidents = (ev.incidents && ev.incidents.length) ? ev.incidents : [];
    var recurrence = (ev.recurrence && ev.recurrence.length) ? ev.recurrence : [];
    var misdir = (ev.misdirection && ev.misdirection.length) ? ev.misdirection : [];

    // --- nav incidents count + meta -------------------------------------
    var ct = $('nav-inc-ct');
    if (ct) {
      ct.textContent = String(incidents.length);
      ct.className = incidents.length ? 'ct alert' : 'ct none';
    }

    // --- leading fault from recurrence[0] --------------------------------
    var leadMod = recurrence.length ? recurrence[0].module : null;
    var leadCount = recurrence.length ? recurrence[0].count : null;

    // rows attributed to the leading module (truthy faulting_module match)
    var moduleRows = rows.filter(function (r) {
      return leadMod && r.faulting_module === leadMod;
    });

    // window = first..last ts among module rows (fallback: all rows)
    var srcRows = moduleRows.length ? moduleRows : rows;
    var times = srcRows.map(function (r) { return parseTs(r.ts); }).filter(Boolean).sort(function (a, b) { return a - b; });
    var fmtDayD = function (d) { return MONTHS[d.getMonth()] + ' ' + d.getDate(); };
    var windowStr = times.length ? (fmtDayD(times[0]) + '–' + fmtDayD(times[times.length - 1])) : '—';

    // crash-class signals among module rows (detail only)
    var CRASH = { bugcheck: 1, dpc_watchdog: 1, dpc_watchdog_hang: 1, tdr: 1, unexpected_shutdown: 1 };
    var crashSignals = moduleRows.filter(function (r) { return CRASH[r.signal]; }).length;
    // headline count = distinct recurring incidents (matches the recurrence chip)
    var hits = (leadCount != null && leadCount > 0) ? leadCount : crashSignals;

    var dumps = moduleRows.filter(function (r) { return r.signal === 'bugcheck'; }).length;

    // --- felt -> was from misdirection -----------------------------------
    // Prefer the highest-confidence pair; on a confidence tie, favour a
    // 'network'-felt correction (the canonical "felt like lag, was the GPU"
    // reveal that the lede narrates). Falls back to any pair otherwise.
    var topMis = null;
    misdir.forEach(function (m) {
      if (!topMis) { topMis = m; return; }
      var c = (m.confidence || 0), tc = (topMis.confidence || 0);
      if (c > tc) { topMis = m; return; }
      if (c === tc && m.truth === 'gpu' && topMis.truth !== 'gpu') topMis = m;
    });
    var felt = topMis ? (FELT_LABEL[topMis.felt] || ('A ' + (topMis.felt || 'system') + ' problem')) : 'A network lag spike';
    var was = topMis ? (TRUTH_LABEL[topMis.truth] || ('A ' + (topMis.truth || 'driver') + ' fault')) : 'The GPU driver stalling';
    txt('ov-felt', felt);
    txt('ov-was', was);

    // --- severity pill ---------------------------------------------------
    var critical = rows.some(function (r) { return r.severity === 'critical'; });
    if (sev) sev.className = 'sev' + (critical ? '' : ' ok');
    txt('ov-sev-t', critical ? 'Critical · cause found' : 'Clear · no active fault');

    // --- headline + lede -------------------------------------------------
    if (leadMod && hits) {
      txt('ov-verdict', 'Your GPU driver crashed your game ' + hits + ' time' + (hits === 1 ? '' : 's'));
      html('ov-lede', 'Logged as freezes and stutters across the recorded window — not the subsystem it felt like. The graphics driver (<strong>' + esc(leadMod) + '</strong>) locked up the system and took the game down with it.');
    } else {
      txt('ov-verdict', 'No active fault — the recorder is clear');
      html('ov-lede', 'No crash-class events attributed to a driver in the current evidence window.');
    }

    // --- facts row -------------------------------------------------------
    txt('ov-window', windowStr);
    txt('ov-module', leadMod ? (leadMod + '.sys') : '—');
    txt('ov-hits', hits ? String(hits) : '0');

    // Confidence: drive the label off the misdirection confidence (the
    // correlator's own score). Only cite a dump count when there are >=2
    // crash dumps so a single dump doesn't read as the whole evidence base.
    var conf = topMis ? topMis.confidence : null;
    var confLabel = (conf != null)
      ? (conf >= 0.8 ? 'High' : conf >= 0.5 ? 'Medium' : 'Low')
      : (dumps ? 'High' : '—');
    var confEl = $('ov-conf');
    if (confEl) {
      if (dumps >= 2) {
        confEl.innerHTML = esc(confLabel) + ' <small>· ' + dumps + ' dumps</small>';
      } else if (recurrence.length) {
        confEl.innerHTML = esc(confLabel) + ' <small>· ' + recurrence[0].count + '× recurrence</small>';
      } else {
        confEl.textContent = confLabel;
      }
    }

    txt('ov-meta', 'case ' + (leadMod || '—'));

    // --- evidence chain --------------------------------------------------
    buildEvidenceChain(rows, incidents);

    // --- gpu subsystem dpc figure (from leading module if present) -------
    var s = snap();
    if (s && s.counters && s.counters.system) {
      txt('gpu-dpc', fixed(s.counters.system.dpcPct, 2) + '% · nominal');
    }
  }

  function buildEvidenceChain(rows, incidents) {
    txt('ev-summary', rows.length + ' signal' + (rows.length === 1 ? '' : 's') + ' · ' + incidents.length + ' incident' + (incidents.length === 1 ? '' : 's'));

    // Prefer the newest crash-class incident for the chain (the design shows
    // a single incident's timeline). Fall back to the most recent rows.
    var chainRows = null;
    if (incidents.length) {
      // newest incident (incidents[] is newest-first per the schema)
      var inc = incidents[0];
      chainRows = (inc.rows || []).slice();
    }
    if (!chainRows || !chainRows.length) {
      chainRows = rows.slice().sort(function (a, b) {
        return (parseTs(b.ts) || 0) - (parseTs(a.ts) || 0);
      }).slice(0, 5).reverse();
    }
    // sort chronological
    chainRows.sort(function (a, b) { return (parseTs(a.ts) || 0) - (parseTs(b.ts) || 0); });

    var host = $('ev-rows');
    if (!host) return;
    if (!chainRows.length) {
      host.innerHTML = '<div class="ev-none">No evidence rows on record.</div>';
      return;
    }
    var out = '';
    chainRows.forEach(function (r) {
      var info = signalInfo(r);
      var kind = (r.evidence_kind === 'observed' || r.evidence_kind === 'inferred' || r.evidence_kind === 'absent') ? r.evidence_kind : 'observed';
      var code = r.signal + (r.cpu != null ? ' · cpu ' + r.cpu : (r.faulting_module ? ' · ' + r.faulting_module : ''));
      out += '<button class="evrow" type="button">' +
        '<span class="ts">' + esc(fmtDayTime(r.ts)) + '</span>' +
        '<span><span class="ev-h">' + esc(info.h) + '</span><span class="ev-c">' + esc(code) + '</span></span>' +
        '<span class="desc">' + info.d + '</span>' +
        '<span class="kind ' + kind + '">' + kind + '</span>' +
        '<span class="chev">›</span>' +
        '</button>';
    });
    host.innerHTML = out;
  }

  /* ----- Incidents view -------------------------------------------------- */
  function severityOf(inc) {
    var best = 'info';
    (inc.rows || []).forEach(function (r) {
      if ((SEV_RANK[r.severity] || 0) > (SEV_RANK[best] || 0)) best = r.severity;
    });
    return best;
  }
  function incidentTitle(inc) {
    var rows = inc.rows || [];
    var mod = null, hasGpu = false, hasNet = false, hasInput = false, hasMis = false;
    rows.forEach(function (r) {
      if (r.faulting_module && r.faulting_module.length) mod = r.faulting_module;
      if (r.subsystem === 'gpu') hasGpu = true;
      if (r.subsystem === 'network') hasNet = true;
      if (r.subsystem === 'input') hasInput = true;
      if (r.signal === 'misdiagnosis_correction') hasMis = true;
    });
    if (hasMis && (hasNet || hasInput)) return 'Mistaken for ' + (hasNet ? 'network lag' : 'input stutter');
    if (mod === 'nvlddmkm') return 'GPU driver hang';
    if (hasGpu) return 'GPU driver fault';
    return 'System incident';
  }
  function incidentSub(inc) {
    var rows = inc.rows || [];
    var sigs = {};
    rows.forEach(function (r) { sigs[r.signal] = (sigs[r.signal] || 0) + 1; });
    var parts = [];
    if (sigs.bugcheck) parts.push('crash dump confirmed');
    if (sigs.dpc_watchdog || sigs.dpc_watchdog_hang) parts.push('watchdog timeout');
    if (sigs.misdiagnosis_correction) parts.push('felt like something else');
    if (sigs.cpu0_dpc_pct) parts.push('CPU 0 overloaded');
    if (sigs.regression) parts.push('pattern recurred');
    if (!parts.length) parts.push(rows.length + ' signal' + (rows.length === 1 ? '' : 's'));
    return parts.slice(0, 2).join(' · ');
  }
  function incidentDate(inc) {
    var t = null;
    (inc.rows || []).forEach(function (r) { var d = parseTs(r.ts); if (d && (!t || d > t)) t = d; });
    // also try parsing the id (INC-YYYYMMDD-HHMM)
    if (!t && inc.id) {
      var m = /INC-(\d{4})(\d{2})(\d{2})/.exec(inc.id);
      if (m) t = new Date(+m[1], +m[2] - 1, +m[3]);
    }
    return t ? (MONTHS[t.getMonth()] + ' ' + t.getDate()) : '—';
  }

  function buildIncidents() {
    var ev = evid();
    var list = $('inc-list');
    if (!list) return;
    if (!ev || !ev.incidents || !ev.incidents.length) {
      list.innerHTML = '<div class="ev-none">No incidents on record.</div>';
      txt('inc-meta', '0 records');
      return;
    }
    var incidents = ev.incidents;
    txt('inc-meta', incidents.length + ' record' + (incidents.length === 1 ? '' : 's'));

    var out = '';
    incidents.forEach(function (inc) {
      var sev = severityOf(inc);
      var dotCls = sev === 'critical' ? 'bad' : (sev === 'error' || sev === 'warn') ? 'warn' : 'ok';
      // state: any info-level "regression" recurrence with no critical => fixed/holding
      var hasCritical = (inc.rows || []).some(function (r) { return r.severity === 'critical'; });
      var hasUninstall = (inc.rows || []).some(function (r) { return r.signal === 'driver_uninstall'; });
      var hasMis = (inc.rows || []).some(function (r) { return r.signal === 'misdiagnosis_correction'; });
      var stateCls, stateTxt;
      if (hasUninstall) { stateCls = ''; stateTxt = 'fixed'; }
      else if (hasMis && hasCritical) { stateCls = 'fix'; stateTxt = 'fix →'; }
      else if (hasCritical) { stateCls = ''; stateTxt = 'fixed'; }
      else { stateCls = 'clr'; stateTxt = 'clear'; }

      out += '<button class="irow" type="button">' +
        '<span class="idot ' + dotCls + '"></span>' +
        '<span class="when">' + esc(incidentDate(inc)) + '</span>' +
        '<span><span class="v">' + esc(incidentTitle(inc)) + '</span><span class="x">' + esc(incidentSub(inc)) + ' · ' + esc(inc.id || '') + '</span></span>' +
        '<span class="istate ' + stateCls + '">' + esc(stateTxt) + '</span>' +
        '</button>';
    });
    list.innerHTML = out;

    // symptom vs cause from misdirection[]
    var sxc = $('inc-sxc');
    if (sxc) {
      var head = '<div class="sxc-r sxc-h"><div>What it felt like</div><div>What it actually was</div><div>Conf.</div></div>';
      var body = '';
      var mis = (ev.misdirection && ev.misdirection.length) ? ev.misdirection : [];
      if (!mis.length) {
        body = '<div class="sxc-r"><div class="felt">—</div><div class="cause">No corrections on record</div><div class="cf">—</div></div>';
      } else {
        mis.forEach(function (m) {
          var feltL = FELT_LABEL[m.felt] || ('A ' + (m.felt || '?') + ' problem');
          var causeL = TRUTH_LABEL[m.truth] || ((m.truth || '?') + ' fault');
          var c = (typeof m.confidence === 'number') ? m.confidence.toFixed(2) : '—';
          body += '<div class="sxc-r"><div class="felt">' + esc(feltL) + '</div><div class="cause">' + esc(causeL) + '</div><div class="cf">' + esc(c) + '</div></div>';
        });
      }
      sxc.innerHTML = head + body;
    }
  }

  /* ----- History view ---------------------------------------------------- */
  function buildHistory() {
    var h = hist();
    var recent = $('hist-recent');

    // crash-class events from evidence give the "days clean" story; here we
    // surface the rolling counter history as recent samples.
    if (!h.length) {
      txt('hist-meta', 'no samples recorded');
      txt('hist-headline', 'No history recorded yet');
      txt('hist-lede', 'Once the recorder accumulates samples, the rolling timeline shows here.');
      if (recent) recent.innerHTML = '<div class="ev-none">No samples yet.</div>';
      return;
    }

    // span of history
    var first = parseTs(h[0].timestamp), last = parseTs(h[h.length - 1].timestamp);
    var spanDays = (first && last) ? Math.max(1, Math.round((last - first) / 86400000)) : null;
    var spikes = h.filter(function (p) {
      return p.spikes && (p.spikes.totalDpcSpike || p.spikes.totalInterruptSpike || (p.spikes.highDpcCpus && p.spikes.highDpcCpus.length));
    }).length;

    txt('hist-meta', h.length + ' samples' + (spanDays ? ' · ' + spanDays + 'd window' : ''));
    if (spikes === 0) {
      txt('hist-headline', 'Running clean across the recorded window');
      txt('hist-lede', 'No DPC or interrupt spikes across ' + h.length + ' samples. The fix is holding.');
    } else {
      txt('hist-headline', spikes + ' spike' + (spikes === 1 ? '' : 's') + ' in the window');
      txt('hist-lede', spikes + ' sample' + (spikes === 1 ? '' : 's') + ' crossed a DPC or interrupt threshold. Most of the window was quiet.');
    }

    // show the last N samples as cards
    if (recent) {
      var tail = h.slice(-8).reverse();
      var out = '';
      tail.forEach(function (p) {
        var sp = p.spikes && (p.spikes.totalDpcSpike || p.spikes.totalInterruptSpike || (p.spikes.highDpcCpus && p.spikes.highDpcCpus.length));
        var dpc = (p.system && typeof p.system.dpcPct === 'number') ? p.system.dpcPct.toFixed(2) : '—';
        out += '<button class="rc ' + (sp ? 'spike' : 'well') + '" type="button">' +
          '<span class="dt">' + esc(fmtDayTime(p.timestamp)) + '</span>' +
          '<span class="ti">' + (sp ? 'Spike' : 'Clean') + '</span>' +
          '<span class="tg">DPC ' + esc(dpc) + '%</span>' +
          '</button>';
      });
      recent.innerHTML = out;
    }
  }

  /* ================================================================== */
  /* LIVE SNAPSHOT — render + 2s dynamic-script reload                   */
  /* ================================================================== */

  function seedSparkFromHistory() {
    var h = hist();
    if (!h.length) return;
    var tail = h.slice(-SPARK_N);
    State.dpcBuf = tail.map(function (p) {
      return (p.system && typeof p.system.dpcPct === 'number') ? p.system.dpcPct : 0;
    });
  }

  function drawSpark() {
    var line = $('dpc-line'), area = $('dpc-area'), nowDot = $('dpc-now');
    if (!line || !area || !nowDot) return;
    var buf = State.dpcBuf;
    if (!buf.length) { line.setAttribute('d', ''); area.setAttribute('d', ''); return; }
    var w = 240, h = 38, max = 1.1; // 1.0% threshold sits at y=11 (matches <line>)
    var n = buf.length;
    var pts = buf.map(function (v, i) {
      var x = n === 1 ? w : (i / (n - 1) * w);
      var y = h - (clamp(v, 0, max) / max) * h;
      return x.toFixed(1) + ',' + y.toFixed(1);
    });
    line.setAttribute('d', 'M' + pts.join(' L'));
    area.setAttribute('d', 'M0,' + h + ' L' + pts.join(' L') + ' L' + w + ',' + h + ' Z');
    var lastY = h - (clamp(buf[n - 1], 0, max) / max) * h;
    nowDot.setAttribute('cy', lastY.toFixed(1));
  }

  function setMeter(barId, pctId, pct, hotAt) {
    var bar = $(barId), lab = $(pctId);
    if (pct == null) { if (bar) bar.style.width = '0%'; if (lab) lab.textContent = '—'; return; }
    var p = clamp(pct, 0, 100);
    if (bar) {
      bar.style.width = p.toFixed(0) + '%';
      bar.classList.toggle('hot', hotAt != null && pct >= hotAt);
    }
    if (lab) lab.textContent = Math.round(pct) + '%';
  }

  function renderLive() {
    var s = snap();

    // --- collector staleness ----
    var aliveNow = false;
    if (s && s.timestamp) {
      var ts = parseTs(s.timestamp);
      if (ts) aliveNow = (Date.now() - ts.getTime()) < STALE_THRESHOLD_MS;
    }
    State.alive = aliveNow;
    updateStatusBar();

    if (!s || !s.counters || !s.counters.system) {
      // degrade: leave placeholders, but keep sparkline from history
      drawSpark();
      return;
    }
    var sys = s.counters.system;

    // DPC headline + sparkline accumulation
    var dpc = num(sys.dpcPct);
    if (dpc != null) {
      State.dpcBuf.push(dpc);
      if (State.dpcBuf.length > SPARK_N) State.dpcBuf.shift();
      html('dpc-v', dpc.toFixed(2) + '<small>%</small>');
    }
    drawSpark();

    // Frame pacing: not in snapshot — derive a proxy from interrupt load so
    // the meter reads live. Labelled honestly as a pacing-pressure stand-in.
    var fpProxy = num(sys.intrPct);
    if (fpProxy != null) {
      var fpMs = 7.0 + clamp(fpProxy, 0, 8) * 0.8;
      html('fp-v', fpMs.toFixed(1) + '<small>ms</small>');
      setMeter('fp-bar', null, clamp(fpMs / 16 * 100, 0, 100), null);
    }

    // Engine meters from real per-CPU data:
    //  GPU  -> busiest core's DPC% (nvlddmkm DPC lands on a GPU core)
    //  CPU0 -> cpu0 interrupt%
    //  NIC  -> external RTT mapped to a small load proxy
    var perCpu = (s.counters.perCpu && s.counters.perCpu.length) ? s.counters.perCpu : [];
    var maxDpc = 0, cpu0Intr = null;
    perCpu.forEach(function (c) {
      if (typeof c.dpcPct === 'number' && c.dpcPct > maxDpc) maxDpc = c.dpcPct;
      if (c.cpu === 0 && typeof c.intrPct === 'number') cpu0Intr = c.intrPct;
    });
    setMeter('e-gpu', 'p-gpu', clamp(maxDpc * 12, 0, 100), 80);
    setMeter('e-cpu', 'p-cpu', cpu0Intr == null ? null : clamp(cpu0Intr * 10, 0, 100), 60);

    var net = s.network;
    var nicPct = null;
    if (net && net.targets && net.targets.length) {
      var rtt = num(net.targets[0].rttMs);
      if (rtt != null) nicPct = clamp(rtt * 4, 0, 100); // low RTT => low load
    }
    setMeter('e-nic', 'p-nic', nicPct, 70);

    // Recorder card
    if (s.meta) {
      txt('rec-host', s.meta.hostname || '—');
      txt('rec-samples', s.meta.sampleCount != null ? String(s.meta.sampleCount) : '—');
      txt('rec-int', s.meta.intervalSec != null ? (s.meta.intervalSec + 's') : '—');
      txt('set-rec', 'on · ' + (s.meta.intervalSec != null ? s.meta.intervalSec + 's' : '—'));
      txt('st-host', s.meta.hostname || '—');
    }

    // Uptime anchor: first snapshot timestamp we observed
    if (!State.bootTs && s.timestamp) State.bootTs = parseTs(s.timestamp);

    // Recorder recent checks — last few history points
    var checks = $('rec-checks');
    if (checks) {
      var h = hist();
      if (h.length) {
        var tail = h.slice(-3).reverse();
        var out = '';
        tail.forEach(function (p) {
          var sp = p.spikes && (p.spikes.totalDpcSpike || p.spikes.totalInterruptSpike || (p.spikes.highDpcCpus && p.spikes.highDpcCpus.length));
          var d = parseTs(p.timestamp);
          var clock = d ? (pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds())) : '--:--:--';
          out += '<div class="chk"><span class="d ' + (sp ? 'spike' : '') + '"></span> ' + esc(clock) + ' — ' + (sp ? 'spike' : 'clean') + '</div>';
        });
        checks.innerHTML = out;
      } else {
        checks.innerHTML = '<div class="chk"><span class="d"></span> live — ' + (aliveNow ? 'clean' : 'stale') + '</div>';
      }
    }

    // Network subsystem pane (live)
    if (net) {
      txt('net-verdict', net.verdict || '—');
      txt('net-gw', (net.gateway && net.gateway.rttMs != null) ? (net.gateway.rttMs + ' ms') : '—');
      if (net.targets && net.targets.length) {
        var ext = net.targets.map(function (t) { return (t.rttMs != null ? t.rttMs + 'ms' : '?') + ' (' + (t.host || '?') + ')'; }).join(', ');
        txt('net-ext', ext);
      }
      if (net.packetLoss) {
        txt('net-loss', 'gw ' + (net.packetLoss.gateway != null ? net.packetLoss.gateway : '?') + ' · ext ' + (net.packetLoss.external != null ? net.packetLoss.external : '?'));
      }
      var verdictOk = net.verdict === 'stable';
      txt('net-h', verdictOk ? 'Network is stable' : 'Network: ' + (net.verdict || 'unknown'));
    }
  }

  function updateStatusBar() {
    var s = snap();
    var dpc = (s && s.counters && s.counters.system && typeof s.counters.system.dpcPct === 'number')
      ? s.counters.system.dpcPct.toFixed(2) + '%' : '—';
    var dpcEl = $('st-dpc');
    if (dpcEl) {
      dpcEl.textContent = dpc;
      var hot = s && s.counters && s.counters.system && s.counters.system.dpcPct >= 1.0;
      dpcEl.className = hot ? 'bad' : 'ok';
    }
    txt('st-rec', State.alive ? 'Recording' : 'Collector idle');
    var dots = [$('st-dot'), $('side-dot')];
    dots.forEach(function (d) {
      if (!d) return;
      d.className = 'dot ' + (State.alive ? 'live' : 'dead');
    });
  }

  /* uptime + last-check ticker (1s) */
  function tick() {
    if (document.hidden) return;
    State.lastCheck++;
    txt('st-last', String(State.lastCheck));
    if (State.bootTs) {
      var up = Math.floor((Date.now() - State.bootTs.getTime()) / 1000);
      txt('rec-up', fmtClock(up));
      txt('rec-elapsed', fmtClock(up));
    }
  }

  /* dynamic <script> reload of snapshot.js with ?t= cache-bust.
   * Re-executing the file re-assigns window.MONITOR_SNAPSHOT, then we
   * re-render live values. No fetch — file:// safe. */
  function refreshSnapshot() {
    if (document.hidden) return;
    var old = document.getElementById('snapshotScript');
    if (old && old.parentNode) old.parentNode.removeChild(old);

    var script = document.createElement('script');
    script.id = 'snapshotScript';
    script.src = 'data/snapshot.js?t=' + Date.now();
    script.onerror = function () {
      State.alive = false;
      updateStatusBar();
    };
    script.onload = function () {
      State.lastCheck = 0;
      renderLive();
    };
    document.body.appendChild(script);
  }

  /* ================================================================== */
  /* BOOT                                                                */
  /* ================================================================== */
  function boot() {
    handleRoute();              // hash -> initial view

    // build evidence-derived panes once from the boot-loaded globals
    buildVerdict();
    buildIncidents();
    buildHistory();

    // seed sparkline + first live render from already-loaded snapshot
    seedSparkFromHistory();
    renderLive();

    // tickers
    setInterval(tick, 1000);
    setInterval(refreshSnapshot, REFRESH_INTERVAL_MS);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
