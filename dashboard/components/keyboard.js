// ============================================================
// KEYBOARD NAVIGATION — vim-style keybindings for dashboard
// Depends on globals: AppState, navigateTo, render, BASELINE_ID
// ============================================================
(function() {
  'use strict';

  var focusedRowIndex = -1;
  var helpVisible = false;

  // ----------------------------------------------------------
  // KEY BINDINGS
  // ----------------------------------------------------------
  var KEYBINDINGS = {
    // Table view
    'j':         { view: 'table', action: 'nextRow', desc: 'Next row' },
    'k':         { view: 'table', action: 'prevRow', desc: 'Previous row' },
    'ArrowDown': { view: 'table', action: 'nextRow', desc: 'Next row' },
    'ArrowUp':   { view: 'table', action: 'prevRow', desc: 'Previous row' },
    'Enter':     { view: 'table', action: 'openDetail', desc: 'Open detail' },
    'c':         { view: 'table', action: 'toggleSelect', desc: 'Toggle select' },
    '/':         { view: 'table', action: 'focusSearch', desc: 'Focus search' },
    'b':         { view: 'table', action: 'jumpToBaseline', desc: 'Jump to baseline' },

    // Detail view
    'j__detail': { view: 'detail', action: 'nextSection', desc: 'Next section' },
    'k__detail': { view: 'detail', action: 'prevSection', desc: 'Previous section' },

    // Global
    'Escape':    { view: '*', action: 'back', desc: 'Back / close' },
    '?':         { view: '*', action: 'showHelp', desc: 'Show help' },
  };

  // ----------------------------------------------------------
  // TABLE ROW FOCUS
  // ----------------------------------------------------------
  function getTableRows() {
    var tbody = document.querySelector('.exp-table tbody');
    if (!tbody) return [];
    return Array.prototype.slice.call(tbody.querySelectorAll('tr'));
  }

  function focusRow(index) {
    var rows = getTableRows();
    if (rows.length === 0) return;

    // Clamp / wrap
    if (index < 0) index = rows.length - 1;
    if (index >= rows.length) index = 0;

    // Remove existing focus
    var prev = document.querySelector('.kbd-focused');
    if (prev) prev.classList.remove('kbd-focused');

    // Apply focus
    rows[index].classList.add('kbd-focused');
    rows[index].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    focusedRowIndex = index;
  }

  function nextRow() {
    focusRow(focusedRowIndex + 1);
  }

  function prevRow() {
    focusRow(focusedRowIndex - 1);
  }

  // ----------------------------------------------------------
  // ACTIONS
  // ----------------------------------------------------------
  function openDetail() {
    var rows = getTableRows();
    if (focusedRowIndex < 0 || focusedRowIndex >= rows.length) return;
    var link = rows[focusedRowIndex].querySelector('a.name-link');
    if (link && link.getAttribute('href')) {
      navigateTo(link.getAttribute('href'));
    }
  }

  function toggleSelectAction() {
    var rows = getTableRows();
    if (focusedRowIndex < 0 || focusedRowIndex >= rows.length) return;
    var cb = rows[focusedRowIndex].querySelector('input[type="checkbox"]');
    if (cb) {
      cb.checked = !cb.checked;
      cb.dispatchEvent(new Event('change', { bubbles: true }));
    }
  }

  function focusSearch() {
    var input = document.getElementById('searchInput');
    if (input) {
      input.focus();
      return true; // signal to preventDefault (block '/' from typing)
    }
    return false;
  }

  function jumpToBaseline() {
    var rows = getTableRows();
    for (var i = 0; i < rows.length; i++) {
      var link = rows[i].querySelector('a.name-link');
      if (link) {
        var href = link.getAttribute('href') || '';
        if (href.indexOf(BASELINE_ID) !== -1) {
          focusRow(i);
          return;
        }
      }
    }
    // Fallback: focus first row
    if (rows.length > 0) focusRow(0);
  }

  function back() {
    // Close help if showing
    if (helpVisible) { hideHelp(); return; }

    // Blur focused input
    if (document.activeElement && document.activeElement.matches('input, select, textarea')) {
      document.activeElement.blur();
      return;
    }

    // Navigate back to table from detail/compare
    if (AppState.view === 'detail' || AppState.view === 'compare') {
      navigateTo('#table');
    }
  }

  // ----------------------------------------------------------
  // DETAIL SECTION NAVIGATION
  // ----------------------------------------------------------
  function getSections() {
    var container = document.getElementById('detailView');
    if (!container) return [];
    return Array.prototype.slice.call(container.querySelectorAll('.section-header, .chart-card, .metric-card'));
  }

  function nextSection() {
    var sections = getSections();
    if (sections.length === 0) return;
    var current = findVisibleSectionIndex(sections);
    var next = Math.min(current + 1, sections.length - 1);
    sections[next].scrollIntoView({ block: 'start', behavior: 'smooth' });
  }

  function prevSection() {
    var sections = getSections();
    if (sections.length === 0) return;
    var current = findVisibleSectionIndex(sections);
    var prev = Math.max(current - 1, 0);
    sections[prev].scrollIntoView({ block: 'start', behavior: 'smooth' });
  }

  function findVisibleSectionIndex(sections) {
    for (var i = 0; i < sections.length; i++) {
      var rect = sections[i].getBoundingClientRect();
      if (rect.top >= 0) return i;
    }
    return sections.length - 1;
  }

  // ----------------------------------------------------------
  // HELP OVERLAY
  // ----------------------------------------------------------
  function showHelp() {
    if (helpVisible) { hideHelp(); return; }

    var overlay = document.createElement('div');
    overlay.id = 'kbd-help-overlay';
    overlay.innerHTML = buildHelpContent();

    // Close on click outside the panel
    overlay.addEventListener('click', function(e) {
      if (e.target === overlay) hideHelp();
    });

    document.body.appendChild(overlay);
    helpVisible = true;
  }

  function hideHelp() {
    var overlay = document.getElementById('kbd-help-overlay');
    if (overlay) overlay.parentNode.removeChild(overlay);
    helpVisible = false;
  }

  function buildHelpContent() {
    var html = '<div class="kbd-help-panel">';
    html += '<div class="kbd-help-title">Keyboard Shortcuts</div>';
    html += '<div class="kbd-help-grid">';

    // Deduplicate display (skip arrow aliases and __detail suffixed keys)
    var shown = {};
    var displayOrder = ['j', 'k', 'Enter', 'c', '/', 'b', 'Escape', '?'];

    displayOrder.forEach(function(key) {
      var binding = KEYBINDINGS[key];
      if (!binding || shown[binding.action]) return;
      shown[binding.action] = true;
      var viewLabel = binding.view === '*' ? 'Global' : binding.view;
      html += '<div class="kbd-help-row">';
      html += '<kbd class="kbd-key">' + escHtmlKey(key) + '</kbd>';
      html += '<span class="kbd-desc">' + binding.desc + '</span>';
      html += '<span class="kbd-view">' + viewLabel + '</span>';
      html += '</div>';
    });

    // Detail-specific
    html += '<div class="kbd-help-row">';
    html += '<kbd class="kbd-key">j / k</kbd>';
    html += '<span class="kbd-desc">Next / prev section</span>';
    html += '<span class="kbd-view">detail</span>';
    html += '</div>';

    html += '</div>'; // grid
    html += '<div class="kbd-help-footer">Press <kbd>?</kbd> or <kbd>Esc</kbd> to close</div>';
    html += '</div>'; // panel
    return html;
  }

  function escHtmlKey(key) {
    if (key === '/') return '/';
    if (key === '?') return '?';
    if (key === 'Escape') return 'Esc';
    if (key === 'Enter') return 'Enter';
    return key;
  }

  // ----------------------------------------------------------
  // KEYDOWN HANDLER
  // ----------------------------------------------------------
  function handleKeydown(e) {
    // Never intercept when modifier keys are held (browser shortcuts)
    if (e.ctrlKey || e.altKey || e.metaKey) return;

    // Skip if focus is in form element (except Escape to blur)
    if (e.target.matches('input, select, textarea')) {
      if (e.key === 'Escape') {
        e.target.blur();
        e.preventDefault();
      }
      return;
    }

    // Resolve binding — check view-specific first, then global
    var binding = null;
    var currentView = AppState.view;

    // View-specific override (detail view j/k)
    if (currentView === 'detail') {
      var detailKey = e.key + '__detail';
      if (KEYBINDINGS[detailKey]) {
        binding = KEYBINDINGS[detailKey];
      }
    }

    // Standard lookup
    if (!binding && KEYBINDINGS[e.key]) {
      var candidate = KEYBINDINGS[e.key];
      if (candidate.view === '*' || candidate.view === currentView) {
        binding = candidate;
      }
    }

    if (!binding) return;

    // Execute action
    var handled = true;
    switch (binding.action) {
      case 'nextRow':        nextRow(); break;
      case 'prevRow':        prevRow(); break;
      case 'openDetail':     openDetail(); break;
      case 'toggleSelect':   toggleSelectAction(); break;
      case 'focusSearch':    focusSearch(); break;
      case 'jumpToBaseline': jumpToBaseline(); break;
      case 'back':           back(); break;
      case 'showHelp':       showHelp(); break;
      case 'nextSection':    nextSection(); break;
      case 'prevSection':    prevSection(); break;
      default: handled = false;
    }

    if (handled) {
      e.preventDefault();
    }
  }

  // ----------------------------------------------------------
  // STYLE INJECTION
  // ----------------------------------------------------------
  function injectStyles() {
    var style = document.createElement('style');
    style.id = 'kbd-styles';
    style.textContent = [
      '.kbd-focused { outline: 2px solid #3b82f6; outline-offset: -2px; background: rgba(59,130,246,0.08) !important; }',
      '#kbd-help-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); display: flex; align-items: center; justify-content: center; z-index: 9999; }',
      '.kbd-help-panel { background: #0f1b2e; border: 1px solid #1e3a5f; border-radius: 12px; padding: 24px 32px; max-width: 420px; width: 90%; box-shadow: 0 20px 60px rgba(0,0,0,0.5); }',
      '.kbd-help-title { font-size: 18px; font-weight: 600; color: #e2e8f0; margin-bottom: 16px; text-align: center; }',
      '.kbd-help-grid { display: flex; flex-direction: column; gap: 8px; }',
      '.kbd-help-row { display: flex; align-items: center; gap: 12px; padding: 4px 0; }',
      '.kbd-key { background: #1c2840; border: 1px solid #2d4a6f; border-radius: 4px; padding: 2px 8px; font-family: monospace; font-size: 13px; color: #e2e8f0; min-width: 28px; text-align: center; }',
      '.kbd-desc { flex: 1; color: #94a3b8; font-size: 13px; }',
      '.kbd-view { color: #4a6a8a; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }',
      '.kbd-help-footer { margin-top: 16px; text-align: center; color: #4a6a8a; font-size: 12px; }',
      '.kbd-help-footer kbd { background: #1c2840; border: 1px solid #2d4a6f; border-radius: 3px; padding: 1px 5px; font-family: monospace; font-size: 11px; color: #94a3b8; }',
    ].join('\n');
    document.head.appendChild(style);
  }

  // ----------------------------------------------------------
  // PUBLIC API
  // ----------------------------------------------------------
  function initKeyboard() {
    injectStyles();
    document.addEventListener('keydown', handleKeydown);
  }

  function reapplyFocus() {
    if (AppState.view === 'table' && focusedRowIndex >= 0) {
      var rows = getTableRows();
      if (rows.length > 0) {
        var idx = Math.min(focusedRowIndex, rows.length - 1);
        focusRow(idx);
      }
    }
  }

  // Expose globals
  window.initKeyboard = initKeyboard;
  window.reapplyKeyboardFocus = reapplyFocus;
})();
