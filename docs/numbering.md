# Equation numbering — design & limitations

How `org-latex-to-svg` numbers display math and resolves `\eqref` / `\ref`.
This is the *shipped* design (0.3.0+); it is a **pure front-end** feature gated
behind `org-latex-to-svg-number-equations` (on by default) — no Org/element
awareness leaks into the `latex-to-svg` engine.

The counting algorithm and environment lists are adapted from tecosaur's Org
LaTeX preview (`org-latex-preview.el`; the `--environment-numbering-table` /
`--count-numbered-equations` family), GPL, with two `multline` corrections
(below). The `\eqref`/`\ref` resolution, click-to-jump, and the ground-truth
reconcile are original.

## How a number gets on screen

An equation's number depends on every numbered equation before it, but the
engine caches each fragment in isolation by content hash. We bridge that with
one trick: **prepend `\setcounter{equation}{K}` to the block**, where `K` is the
count of preceding numbered equations. LaTeX then prints the right number, and
because `K` is part of the hashed input the number is cached for free — change
`K` and it re-renders, leave it and it's a cache hit. No engine equation-logic.

`K` comes from a document-order Elisp scan (`--scan-numbering`) that threads a
counter over the numbered environments. Two sources feed the per-block
*consumed* count:

- **Heuristic (fast first guess):** `--count-numbered-equations`, from the
  environment table below. Synchronous, so the whole buffer renders in
  parallel — there is no sequential cold path.
- **Ground truth (authoritative):** each numbered block is rendered with a
  probe `\typeout{L2S=\arabic{equation}}`; the engine captures the final counter
  into a `<hash>.eld` sidecar as `(:v 1 :nums (INITIAL . FINAL))` (INITIAL =
  `K+1` supplied by the front-end via `:metadata`, FINAL read back from LaTeX).
  Then `consumed = FINAL − INITIAL + 1`. Readable on cache hit or miss.

`--reconcile` threads the counter using ground truth where available (heuristic
until a block's metadata exists) and re-renders only the previews whose first
number changed. It runs on the render commands and, debounced via
`org-latex-to-svg-reconcile-idle`, on `after-change-functions` — so numbers
self-heal a short while after an edit. When cached ground truth disagrees with
the heuristic, a reconcile is scheduled to propagate the correction downstream.

## The environment table (`consumed`)

**Single-equation** (consume 1, or 0 if the block has `\nonumber` / `\notag` /
`\tag`): `equation`, `math`, `displaymath`, `multline`, plus `dmath` (breqn),
`empheq`.

**Multi-equation** (one per row, minus suppressed rows): `align`, `alignat`,
`flalign`, `gather`, `eqnarray`, `xalignat`, `xxalignat`, `subequations`, plus
`dseries` / `dgroup` / `darray` (breqn).

**Zero**: every starred form, `\[…\]`, `$$…$$`, inline `$…$` / `\(…\)`.

Row counting for the multi class: `rows = 1 + (top-level \\ separators)`, minus
`\nonumber` / `\notag` / `\tag{` occurrences. Two subtleties, both handled:

- **Nested environments** (`matrix`, `cases`, `array`, `aligned`, …) contain
  `\\` that are *not* equation separators. Before counting, the block is copied
  to a scratch buffer and its nested `\begin…\end` pairs are stripped.
- **`multline` is single-numbered**, not one-per-row — it typesets one number
  for the whole line-broken equation. (The reference implementation both
  misspells it `"multiline"` and miscategorises it as multi; we fix both.)

## `\eqref` / `\ref`

The same scan builds a `label → number` map (per-row for `align`). A reference
fragment is rendered as **plain buffer text** — `(3)` for `\eqref`, `3` for
`\ref`, in the `org-latex-to-svg-reference` face — *not* a LaTeX image, so it
matches the surrounding prose font and tracks theme/zoom for free with no
compile. Each reference preview is click-to-jump (`mouse-1` / `RET` →
`org-latex-to-svg-goto-reference`) to the equation defining its label, and is
refreshed in place by `--reconcile` when the target renumbers.

## Engine boundary

The only engine capability numbering relies on is generic and
equation-unaware: `latex-to-svg` (≥ 0.3.0) captures a caller-supplied number
(`:metadata`) paired with a number a compile emits on
`latex-to-svg-metadata-prefix` lines, caches the pair in a `.eld` sidecar keyed
by the content hash, and exposes it via `latex-to-svg-metadata`. Everything
about equations lives in this front-end.

## Limitations / out of scope

- **`\eqref` / `\ref` to a `\tag`ged equation** — the tag suppresses the
  counter (numbers stay correct), but its literal tag text isn't harvested, so
  the reference doesn't resolve.
- **`subequations` sub-lettering** (`N.a`, `N.b`) isn't modelled; inner
  environments are counted, best-effort.
- **`\numberwithin{equation}{section}`**, custom counters, and user
  `\setcounter` inside math — unsupported (the table would need the section
  counter too).
- **Live per-keystroke renumbering** — numbers refresh after the debounced
  reconcile (or an explicit render), not on every keystroke. A forward `\eqref`
  above its target likewise updates on the next reconcile / full render.
- **Reveal-on-cursor-enter** (editing under a preview without first clearing) is
  a separate, unrelated milestone.
