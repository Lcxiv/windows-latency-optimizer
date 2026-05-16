---
tags: [reference, powershell, ps51, pitfalls, compatibility]
date: 2026-04-06
status: complete
aliases: [PS 5.1 Pitfalls]
---

## Rules (all confidence 0.95 — confirmed multiple times, never contradicted)

### 1. Reserved Variables
Never use these as variable names — PS 5.1 reserves them:
- `$error` → use `$errCount`
- `$pid` → use `$mousePid`
- `$host` → use `$dnsTarget` or `$targetHost`
- `$input`, `$args`, `$this` — also reserved

**Why:** These are automatic variables. Assigning throws "Cannot overwrite variable because it is read-only."

### 2. Unsigned Integer Literals
Never use `[uint32]0xFFFFFFFF`. PS 5.1 interprets hex as signed -1, then cast fails.
- Use decimal: `4294967295` instead of `0xFFFFFFFF`

**Why:** PS 5.1 hex literals are Int32. Values above Int32.MaxValue become negative. Cast to [uint32] throws InvalidCastIConvertible.

### 3. Where-Object .Count Trap
Always wrap `Where-Object` in `@()` when calling `.Count` on the result.
- `@($items | Where-Object { ... }).Count` — correct
- `($items | Where-Object { ... }).Count` — WRONG if single result is a hashtable

**Why:** When Where-Object returns a single `[ordered]@{}`, `.Count` returns the number of keys (11) not 1. `@()` forces array context.

### 4. No Ternary / Null-Coalescing
- No `? :` ternary operators
- No `??` null-coalescing
- No `Join-String`
- Pre-compute values before using in `@{}` hashtable literals

**Why:** These are PS 7+ features. PS 5.1 is the target (Windows built-in).

### 5. String Interpolation in Hashtable Literals
Never use `if/else` inside `@{}` hashtable literal assignments.
- Pre-compute to a variable, then assign: `$val = if (...) { 'a' } else { 'b' }; @{ key = $val }`

**How to apply:** After every PS file edit, run: `[Parser]::ParseFile($path, [ref]$null, [ref]$errors); $errors.Count`
