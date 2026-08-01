# Equation numbering — design note

**Status:** **implemented** (v0.2.0) behind `org-latex-to-svg-number-equations`
(on by default): the Elisp environment table, `\nonumber`/`\notag`/`\tag`
counting, nested-`\\` stripping, the document-order offset table, `\setcounter`
injection into the per-fragment render / cache / regenerate path, a
`label → number` map with `\eqref` / `\ref` rendered as `$(N)$` / `$N$`, and
downstream re-render on re-render of an edited block (`--renumber-following`),
and **click-to-jump** (`mouse-1` / `RET`) from a reference preview to the
equation defining its label (`org-latex-to-svg-goto-reference`). Still
**pending / out of scope:** `\eqref` *to* a `\tag` (tag text isn't harvested),
`subequations` sub-lettering, and truly-automatic renumber on every keystroke
(numbers refresh when the edited block, or a covering region/buffer, is
re-rendered).

## Design principle

Numbering is a **nice-to-have**. It must not dictate the architecture of the
package, must not add an engine dependency, and must not make editing one
equation trigger a document-wide recompile. Everything below follows from
holding that line: we accept **narrower-than-full-LaTeX** numbering in exchange
for keeping the per-fragment cache, the parallel render path, and the engine
boundary exactly as they are today.

This is not speculative: it is essentially the approach tecosaur's Org LaTeX
preview (`org-latex-preview.el`, the `--environment-numbering-table` /
`--count-numbered-equations` / `--count-numbered-equations-multi` /
`--get-numbered-environments` functions) already ships. This note follows that
reference implementation, adapted to our overlay/engine split. Source:
<https://code.tecosaur.net/tec/org-mode.git> (branch with `lisp/org-latex-preview.el`).

## The problem

`org-latex-to-svg` renders each math fragment on its own and the engine caches
it by content hash. That independence is what makes recolouring, rescaling, and
cross-buffer caching cheap. It is also why numbering is hard: an equation's
number depends on every numbered equation before it, so a fragment compiled in
isolation shows `(1)` when it should show `(7)`.

An earlier draft of this note tried to make **LaTeX the authority** on the
numbers (bake `\setcounter`, read the counter back from the compile log via a
new engine "compile-metadata" capability, thread it equation-to-equation). That
bought exact LaTeX semantics but cost a great deal: a new engine API, a
**sequential cold-render path** (equation *i*'s counter came from equation
*i−1*'s compiled output), and a marker-chain propagation state machine. That is
the tail wagging the dog. This note discards that approach.

## Core idea: count in Elisp, render with `\setcounter`

Two independent facts do all the work:

1. **The starting counter of a block depends only on how many numbered
   equations precede it** — a quantity we can compute from the buffer text in a
   single synchronous Elisp pass, with no compilation.

2. **Rendering a block verbatim after `\setcounter{equation}{K}` makes LaTeX
   print the right numbers** — including per-row `align` numbering — with zero
   Elisp involvement, because the engine already renders its input verbatim and
   hashes the whole string.

So the split is:

- **Between-block bookkeeping (Elisp):** compute each block's starting counter
  `K_i` by counting. Pure, synchronous, cheap.
- **Within-block rendering (LaTeX):** prepend `\setcounter{equation}{K_i}` and
  hand the verbatim block to the engine. LaTeX does all the actual numbering.

### The pre-pass

```
K = 0
for each display element e_i in document order:   ; one pass, pure Elisp, no I/O
    K_i = K                                        ; this block's starting counter
    K   = K + (numbers-consumed e_i)               ; from the env table below
    record labels defined in e_i → their numbers   ; for \eqref (see below)
```

This loop runs to completion **before any `latex` process starts**. By the time
we render, every `K_i` is known, so the render step is exactly today's
`--render-region`: fire all elements at once, each independent, fully parallel,
each with its own `\setcounter{equation}{K_i}` prepended.

The dependency that made the old design serial —
`K_i ← compile(e_{i-1})` — is replaced by `K_i ← scan(buffer text)`. No probe,
no chain, **no sequential cold path**, cold and warm alike.

## `numbers-consumed`: the environment table

The one piece of LaTeX knowledge we encode in Elisp is how many numbers each
block consumes. We mirror the reference implementation's environment lists
**verbatim** (see the compatibility note below), which split into two classes.

**Single-equation environments** — consume 1, unless the block contains
`\nonumber` / `\notag` or `\tag{` (then 0). From
`org-latex-preview--numbered-environments-single`:

> `equation`, `math`, `displaymath` (`latex.ltx`);
> `dmath` (`breqn.sty`);
> `empheq` (`empheq.sty`).

**Multi-equation environments** — consume one *row* each, minus suppressed
rows. From `org-latex-preview--numbered-environments-multi`:

> `eqnarray` (`latex.ltx`);
> `align`, `alignat`, `flalign`, `gather`, `multline`,
> `xalignat`, `xxalignat`, `subequations` (`amsmath.sty`);
> `dseries`, `dgroup`, `darray` (`breqn.sty`).

**Zero-numbering** — the starred form of every environment above, plus
`\[…\]`, `$$…$$`, and inline `$…$` / `\(…\)`.

Everything the lists don't recognise consumes 0 rather than being guessed at.

### Two fixes to apply to the reference lists

We copy the lists, but two entries need care — don't paste them blind:

- **`multline` is spelled `"multiline"` in the reference** (a typo; the
  `amsmath` environment is `multline`). As written it never matches
  `\begin{multline}`, so those blocks fall through to "unknown → consumes 0".
  Use the correct spelling `multline`.
- **`multline` consumes exactly 1, not one-per-row.** `multline` typesets a
  *single* numbered equation broken across lines; its `\\` are line breaks, not
  equation separators, and the one number sits on the last line. Listing it
  under the row-counting *multi* class over-counts every additional line. So
  `multline` (and `multline*` → 0) belongs with the **single** environments
  despite `amsmath` grouping it with the aligned displays. This is a genuine
  bug in the reference we should not reproduce.

`subequations` also deserves a flag: it wraps *other* numbered environments and
switches the counter to `N.a`, `N.b`, … — the row-count heuristic doesn't model
that sub-counter. We keep it in the list for parity but note it as best-effort
(its inner environments still count); exact `subequations` sub-lettering is in
the same bucket as `\numberwithin` (out of scope, revisit if asked).

### Counting rows in a multi-equation block

The naive count is `rows = 1 + (top-level \\ separators)`, then
`numbers-consumed = rows − (\nonumber count) − (\tag{ count)`. Two subtleties,
both handled the way the reference implementation does:

- **`\nonumber` / `\notag`** are the only way to express a partially-numbered
  `align` (no starred alternative exists), so they must be counted or every
  number *below* the block silently drifts. One regex.
- **Nested environments** (`matrix`, `cases`, `array`, `aligned`, …) contain
  their own `\\` that are **not** `align` rows. Counting them is the real
  fragility. Fix (from the reference): copy the block into a scratch buffer,
  delete the outer `\begin/\end`, then delete every *inner* `\begin…\end`
  region, and only then count `\\`. This removes the false positives.
- **`\tag{`** decrements the count too (a tagged line does not step the
  `equation` counter). This is the *same one-line decrement* as `\nonumber`, so
  we include it — it keeps downstream numbers correct. Note this is only the
  **counting** side of `\tag`; resolving an `\eqref` *to* a tag's text is a
  separate, deferred concern (see scope).

We never parse any of this to *render* — LaTeX renders the block verbatim and
gets the within-block numbering right on its own. We parse solely so the *next*
block's `K` is correct.

## `\eqref` / `\ref`

Because the pre-pass already assigns every `\label{…}` inside a numbered block
its number, we hold a `label → number` map in Elisp — no `.aux` harvest. An
`\eqref{eq:x}` fragment (which cannot compile in isolation) is rendered as
`$(7)$` so it matches the surrounding SVGs, and its overlay can be made
click-to-jump since we know the target's buffer position. Its hash includes
`(7)`, so it re-renders if the target renumbers.

(Per-row labels in `align` map to that row's number; we assign labels as we walk
rows within the block. This is the one place the row walk needs slightly more
than a `\\` count.)

## Editing / invalidation — why it stays cheap

A block's number depends only on how many numbered blocks precede it, so:

- **Edit a block's body without changing its `numbers-consumed`** → every `K`
  below is unchanged → every downstream hash is unchanged → **only the edited
  block re-renders.** Nothing downstream recompiles. Crucially, the Elisp
  pre-pass *detects this locally* (the count is unchanged) without compiling
  anything to find out.
- **Add / remove / reorder a number** → the `K`s below genuinely shift, so those
  blocks must re-render — but that is inherent to numbering, not an artifact.
  New `K`s are known instantly from the pre-pass; blocks whose number didn't
  actually change are cache hits.

There is no whole-document recompile on an ordinary edit, and no bespoke
propagation state machine. Following the reference implementation, when a
numbered environment regenerates we simply **re-place it and every numbered
environment after it** (`--get-numbered-environments` from the block's end to
`point-max`); blocks whose number didn't change are cache hits, so the cost is
dominated by the ones that genuinely renumbered. No marker chain, no
early-stop-when-the-counter-stabilises logic — the cache makes the simple
"re-do everything below" cheap.

Editing a *fragment* (not an environment) can't change any counter, so it never
triggers downstream re-placement.

## Engine impact: none

Numbering is **pure front-end**. The engine (`latex-to-svg`) needs no changes:
`\setcounter{equation}{K}\n<block verbatim>` is already valid verbatim input it
will render and hash. The old design's "capture compile metadata" engine
addition existed only to read numbers back from the compiler; since Elisp now
computes them, it is unnecessary. The engine boundary is untouched.

## Scope — supported, and explicitly not

**Supported** — the full reference environment set (see the table above):

- Single: `equation`, `math`, `displaymath`, `dmath` (breqn), `empheq`,
  and `multline` (corrected to consume 1).
- Multi: `eqnarray`, `align`, `alignat`, `flalign`, `gather`, `xalignat`,
  `xxalignat`, `dseries`, `dgroup`, `darray` — including partial numbering via
  `\nonumber` / `\notag` and nested-environment `\\` stripping.
- `subequations` best-effort (inner environments counted; sub-lettering not).
- All `*` forms, `\[…\]`, `$$…$$`, inline math (all consume 0).
- `\label` / `\eqref` / `\ref` within the above, resolved from the Elisp map.

(breqn's `dmath`/`dseries`/… and `empheq` only matter if the user loads those
packages; harmless to list otherwise.)

**Explicitly not supported (documented limitations):**

- **`\eqref` / `\ref` *to* a `\tag`ged equation.** We count `\tag{` correctly
  (it suppresses the counter step), so numbers stay right, but resolving a
  reference to a tag's *literal text* is deferred with the rest of `\eqref`.
- **`\numberwithin{equation}{section}`** and other section-relative schemes —
  would require tracking the section counter too.
- **Custom / user-defined numbered environments** and user `\setcounter` inside
  math — the env table won't know them (treated as consuming 0). (The env
  table is easy to extend if a specific package — e.g. `breqn`'s
  `dmath`/`dgroup` — is wanted; the reference implementation lists those too.)

These are the accepted cost of not making LaTeX the authority. When we *are*
right about the count, LaTeX still renders the number, so the typography is
exact.

## Open questions / decide later

- **Default on or off?** Off-by-default is defensible (numbering is a
  nice-to-have and adds a pre-pass); gated behind
  `org-latex-to-svg-number-equations`.
- **When does the pre-pass run?** On the whole-buffer render command for sure.
  Whether to also hook a debounced `after-change` (so numbers self-heal as you
  type above an equation) or leave that to the next explicit render is a
  polish question, not an architectural one.
- **`\eqref` in v1 or a follow-up?** The counting half is v1; the
  `label → number` map + click-to-jump overlay is a clean, separable second
  step.

## Compatibility with the reference implementation

**Non-goal to diverge.** We deliberately mirror tec's environment lists and
counting semantics (single/multi split, `\nonumber`/`\notag`/`\tag{` decrements,
nested-`\\` stripping) so that a document numbers **identically** under
`org-latex-to-svg` and under tec's `org-latex-preview`. The two `multline`
corrections above are the only intentional differences, and they fix outright
bugs (a misspelling and a miscategorisation), so they don't break that promise
in practice. If the reference list grows, we track it rather than inventing our
own.

## Responsibility split

- **`latex-to-svg` (engine):** unchanged. Renders `\setcounter{…}<block>`
  verbatim and hashes it like any other input. No equation awareness.
- **`org-latex-to-svg` (front-end):** the entire feature — the pre-pass counter,
  the environment table + `\nonumber` counting, `\setcounter` injection, the
  `label → number` map and `\eqref` rendering, and re-placing overlays whose
  `K` changed. Gated behind `org-latex-to-svg-number-equations`.
