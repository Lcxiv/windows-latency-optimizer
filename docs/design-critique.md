# Design Critique: LatencyGuard Symptom Picker

## Overall Impression

The symptom-first concept is strong -- asking "What are you experiencing?" immediately communicates that this tool understands the user's pain. But the execution undermines the concept with broken text colors, cramped spacing, and a layout that doesn't feel like a premium gaming tool. The bones are good; the surface needs polish.

---

## Usability

| Finding | Severity | Recommendation |
|---------|----------|----------------|
| **Button text renders black on dark bg** -- `.symptom-card` is a `<button>` that doesn't inherit color. Title and icon are `rgb(0,0,0)` on `#111827`. Invisible on some monitors. | CRITICAL | Add `color: var(--text); font-family: inherit;` to `.symptom-card` |
| **No hover feedback visible** -- hover state adds `transform: translateY(-2px)` but the color shift is subtle since text is already broken | HIGH | Fix colors first, then add a visible glow or border-color transition |
| **Export button in header has no context** -- on the symptom picker screen, there's nothing to export yet. Confusing affordance. | MODERATE | Hide Export when `state.findings` is null, or disable it with a tooltip |
| **"Simple/Expert" toggle doesn't map to symptom flow** -- users don't think in "modes." The toggle is leftover from the dashboard design. | MODERATE | Consider renaming to "Symptoms / Raw Data" or hiding until after a scan |
| **No keyboard navigation indicators** -- cards are `<button>` elements (good!) but focus states are barely visible at 2px blue outline | MINOR | Add a stronger focus ring or glow effect for keyboard users |

---

## Visual Hierarchy

- **What draws the eye first**: The heading "What are you experiencing?" -- this is correct. The question immediately grounds the user.
- **Reading flow**: Heading -> subheading -> cards. This is natural and good.
- **Emphasis problems**:
  - Cards all have equal visual weight. The most common symptom (Mouse Freezing) should arguably stand out slightly more, or the "Full System Audit" should look distinct as the catch-all.
  - The colored left borders are a nice touch but too subtle at 3px. They don't create enough differentiation between symptoms.
  - Card icons are small (28px emoji) and get lost. They should be the primary visual anchor on each card.
  - The heading at 22px feels undersized for a hero moment. This is THE first thing users see.

---

## Consistency

| Element | Issue | Recommendation |
|---------|-------|----------------|
| **Card font** | `.symptom-card` uses UA default font (`Arial`) instead of app font (`Segoe UI`) because `<button>` doesn't inherit font-family | Add `font-family: inherit` to `.symptom-card` |
| **Card padding** | 22px 18px -- tighter than other cards in the app (metric cards use 14px 16px, but those are smaller) | Fine as-is, but consider matching proportionally |
| **Heading color** | Uses `var(--text)` (white) while the app logo uses `var(--blue)`. The heading could use a color accent. | Add subtle blue gradient or accent to the heading |
| **Grid max-width** | 540px is too narrow at desktop -- cards feel cramped and right column clips at 1200px viewport | Increase to 640px or use `min(90%, 640px)` |
| **Card min-height** | Not set -- cards are different heights based on text length. "Mouse Freezing" card is shorter than "General Sluggishness" | Add `min-height: 140px` for consistent card sizing |

---

## Accessibility

- **Color contrast (CRITICAL)**: Title text is `rgb(0,0,0)` on `rgb(17,24,39)` = **1.05:1 ratio**. WCAG requires 4.5:1 minimum. This is completely broken.
- **Description contrast**: `rgb(139,157,181)` on `rgb(17,24,39)` = ~4.2:1. Barely fails WCAG AA for small text. Needs to be bumped slightly lighter.
- **Touch targets**: Cards are ~100px tall, well above 44px minimum.
- **Keyboard focus**: Focus-visible outline exists but is thin (2px). Adequate but could be improved.
- **Screen reader**: `aria-live` region exists for announcements. Cards are `<button>` with readable text content.

---

## What Works Well

- **Symptom-first mental model** -- asking "What are you experiencing?" is exactly the right UX pattern. Users don't think in system settings; they think in symptoms.
- **Dark theme execution** -- the color palette (`#0b1120` bg, `#111827` surface) is easy on the eyes and feels premium. The semantic colors (green/amber/red) are well-chosen.
- **Colored left borders** -- each symptom has a distinct accent color (red/amber/cyan/purple). Good visual language, just needs to be bolder.
- **Responsive design** -- graceful collapse to single column on mobile. Cards remain readable.
- **Accessibility foundation** -- `<button>` elements, `aria-live` region, `role="tablist"` on mode toggle. The structure is correct; it just needs cosmetic fixes.

---

## Priority Recommendations

### 1. Fix broken text colors (CRITICAL)
The `.symptom-card` button doesn't inherit `color` or `font-family`. Title, icon, and description text is black on a near-black background. This is invisible on many monitors.

**Fix:** Add `color: var(--text); font-family: inherit;` to `.symptom-card`.

### 2. Make cards feel more interactive and premium
Cards currently feel flat and static. For a gaming audience, they should feel responsive and alive.

**Fix:**
- Increase icon size from 28px to 40px
- Add subtle background gradient on hover
- Widen the left border from 3px to 4px
- Add a faint colored glow matching the accent color on hover
- Set `min-height: 140px` for uniform sizing

### 3. Improve the heading hierarchy
"What are you experiencing?" at 22px doesn't feel like a hero moment. The subheading at 13px is too close in size.

**Fix:**
- Bump heading to 26-28px
- Add 2px letter-spacing for a techy feel
- Increase subheading margin-bottom from 28px to 36px for more breathing room

### 4. Widen the grid
540px max-width is too narrow -- the right column clips at typical desktop widths.

**Fix:** Change `.symptom-grid` max-width to `640px` and add `width: 100%`.

### 5. Differentiate "Full System Audit" as the catch-all
The 4th card should feel distinct from the 3 symptom-specific cards. It's the "I don't know / check everything" option.

**Fix:** Give it a different visual treatment -- perhaps span full width at the bottom, or use a dashed border style.
