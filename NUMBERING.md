# Equation numbering — design note

**Status:** proposed, not implemented. This records the plan so we can poke
holes in it before writing code.

## The problem

`org-latex-to-svg` renders each math fragment on its own and caches it by
content hash (the engine, `latex-to-svg`, compiles a fragment once and reuses
the SVG). That independence is what makes recolouring, rescaling, and
cross-buffer caching cheap. It is also exactly why numbering is hard: an
equation's number depends on every numbered equation before it, so a fragment
compiled in isolation has no way to know it should read `(7)` and not `(1)`.

Editing makes it worse: insert a numbered equation and every number below it
shifts by one, so their previews are now wrong and must be redrawn.

The document-preview tools (AUCTeX preview-latex, `texfrag`) get numbering for
free because they compile a whole document. We don't want to give up the
per-fragment cache to match them, so we have to reconstruct the numbers
ourselves — but we can still let LaTeX be the authority on what the numbers
*are*.

## Core idea

Two parts:

1. **Bake the number in with `\setcounter`.** The engine renders its input
   verbatim, so if the fragment we send is

   ```
   \setcounter{equation}{K}%
   <the fragment, verbatim>
   ```

   the equation prints `(K+1)`, and because the engine hashes the whole string,
   the number is part of the cache key: change `K` and it re-renders; leave it
   and it's a cache hit. The engine needs no equation awareness for this.

2. **Let LaTeX tell us the number — never parse the block.** We do not try to
   decide in Elisp whether a block is numbered or how many numbers it consumes.
   LaTeX already knows (including `\nonumber`, `\tag`, `align` rows, and any
   exotic numbered environment). We read it back from the compile.

## Reading the number back

Wrap the fragment with counter probes:

```
\setcounter{equation}{K}%
\typeout{L2S-BEFORE=\arabic{equation}}%
<fragment verbatim>
\typeout{L2S-AFTER=\arabic{equation}}%
```

`\typeout` writes to the LaTeX log / stdout and has no visual effect, so the
SVG is unchanged. From the two values:

| Observation | Meaning |
| --- | --- |
| `AFTER > BEFORE` | numbered; it consumed numbers `BEFORE+1 … AFTER` |
| `AFTER == BEFORE` | no counter step — `\[…\]`, `equation*`, all rows `\nonumber`, **or** a `\tag` (manual label that doesn't step the counter) |

The only state we keep per rendered equation is **`(numbered? . ending-counter)`**
(plus the number itself if we want to show it). `ending-counter` is the `AFTER`
value; it becomes the next equation's `K`.

Note on `\tag`: it shows a manual label and does **not** step `equation`, so its
`ending-counter` is unchanged — which is correct, because a `\tag` must not
shift anything downstream, and it already renders its literal label standalone
with no `\setcounter` needed.

## The chain

Walk the display-math elements in document order and thread the counter:

```
K0 = 0
for each element e_i in order:
    render e_i with \setcounter{equation}{K_i}
    K_{i+1} = ending-counter read back from e_i
    store on e_i's overlay: (input K_i, output K_{i+1}, numbered?)
```

That is the whole model: *set the counter based on the previous equation.*
Inline `$…$` / `\(…\)` don't step the counter and can be skipped for the chain
(they only matter if they contain a `\ref`/`\eqref`).

## What the engine has to add (and only this)

On a cache **hit** the engine doesn't run `latex`, so it wouldn't see the
`\typeout` lines. The fix is one small, generic capability in `latex-to-svg`,
with no equation awareness:

> **Capture and cache compile metadata.** When compiling, collect the
> `\typeout` lines matching a caller-supplied marker (e.g. `L2S-…`) and write
> them to a sidecar next to the SVG (`<hash>.meta`). Expose them, cache hit or
> miss, via something like `(latex-to-svg-metadata LATEX)`.

The engine just returns "values this compile emitted," keyed by the same
content hash. It never learns these are equation numbers — all numbering logic
stays in `org-latex-to-svg`. This also gives us `\eqref` for free (below).

## `\eqref` / `\ref`

An `\eqref{eq:x}` fragment can't compile alone — the label isn't defined in an
isolated fragment. Resolve it instead:

- When rendering the fragment that *defines* `eq:x`, inject its `\label`s and
  read `\newlabel{eq:x}{{7}…}` from that fragment's `.aux` (harvested through
  the same metadata mechanism). LaTeX writes `\newlabel` on the first pass, and
  because we compiled that fragment with the right `\setcounter{K}`, the number
  is the real one. So we get a `label → number` map from LaTeX, not from
  guessing.
- Render the `\eqref` fragment as `$(7)$` (so it matches the surrounding SVGs),
  and — since we know the target's buffer position — make the overlay
  click-to-jump. Its hash includes `(7)`, so it re-renders when the target
  renumbers.

`\tag` labels come from the same `\newlabel` harvest, so a tagged equation's
`\eqref` resolves to the tag text.

## Invalidation — the marker chain

Link the rendered equations in document order (markers, or an ordered list
rebuilt on scan). When an equation re-renders and its **ending counter
changes**, propagate to the next link: recompute its `K`, re-render, check *its*
ending counter, continue — and **stop as soon as an ending counter is
unchanged**, because everything below is then unaffected.

Consequences:

- Edit an unnumbered equation's body → ending counter unchanged → propagation
  stops immediately; nothing downstream re-renders.
- Add/remove a number mid-document → every ending counter below shifts →
  the chain re-renders to the end. Each is a fresh hash, but equations whose
  number didn't actually change are cache hits, so it's cheap.
- Reorder equations → same, bounded by the first point where the counter
  re-synchronises.

## Caveat: the cold path is sequential

Because equation *i*'s `K` is equation *i−1*'s ending counter, a **cold** buffer
(nothing cached) must render in order — you can't start *i* until *i−1*'s
counter is known. Cache hits read the sidecar instantly, so a warm buffer
re-parallelises.

If that ever hurts, the alternative is a **numbers-only probe**: one `latex`
run over *all* the equations at once (no `dvisvgm`), harvesting every
counter/label from the log + aux in a single pass, then render the images
independently with their now-known `\setcounter`s. Same ground truth,
decoupled, but it re-runs a whole-document `latex` on any *structural* edit
(not on theme/zoom/text-only edits). It is the simpler model to reason about;
the per-fragment chain is the more incremental one. Both feed the identical
`\setcounter` render path, so we can start with one and swap later.

## Responsibility split

- **`latex-to-svg` (engine):** one generic addition — capture, cache, and
  expose compile metadata (`\typeout` lines / `.aux` entries) in a sidecar
  keyed by the content hash. No equation awareness.
- **`org-latex-to-svg` (front-end):** everything about numbering — the chain,
  `\setcounter`/`\typeout` injection, per-overlay `(numbered? . N)` state,
  `label → number` harvest and `\eqref` resolution, and the
  propagate-until-counter-stable re-render. Gated behind a
  `org-latex-to-svg-number-equations` option.

## Open questions / decide later

- **Default on or off?** `org-latex-preview-numbered` defaulted on; numbering
  adds the sequential cold path and the propagation cost, so off-by-default is
  also defensible.
- **`equation` counter only, or others?** Start with `equation` (covers
  `amsmath` display environments). `\tag` needs no counter. Custom counters are
  out of scope.
- **Chain vs whole-document probe** as the first implementation. The chain fits
  the per-fragment cache philosophy; the probe is simpler. Leaning chain, with
  the probe documented as the fallback.
- **Where the number map lives across edits** — recompute on the existing
  whole-buffer render / debounced `after-change`, or keep a persistent chain
  structure with markers. The marker chain enables the early-stop propagation
  but is more state to maintain.
- **Multiply-numbered blocks** (`align` with several rows): the chain only needs
  the block's ending counter, which the probe gives directly; per-row numbers
  (for a `\label` on a specific row) come from `\newlabel` in the aux.

## Out of scope (for now)

- Section-relative numbering (`\numberwithin{equation}{section}`) — would need
  the section counter too; revisit if asked.
- Inline baseline alignment (a separate quality item, unrelated to numbering).
