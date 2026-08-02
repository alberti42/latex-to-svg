# latex-to-svg

SVG LaTeX-math previews for Emacs markup buffers, on top of the
[`latex-to-svg-backend`](https://github.com/alberti42/latex-to-svg-backend)
rendering engine.

This repo is the **front-end**: a shared core plus thin per-mode adaptors.

- **`latex-to-svg-frontend`** — the core: math detection, overlay lifecycle,
  equation numbering, `\ref`/`\eqref` resolution, reveal-on-cursor editing,
  render-on-leave, and theme/zoom refresh. Knows nothing about any markup.
- **`latex-to-svg-for-markdown`** — Markdown adaptor.
- **`latex-to-svg-for-org`** — Org adaptor.

```
  latex-to-svg-for-markdown ─┐
                             ├─▶ latex-to-svg-frontend ─▶ latex-to-svg-backend
  latex-to-svg-for-org ──────┘        (this repo)              (engine)
```

You install an **adaptor**; it pulls in the frontend core and the backend
engine as dependencies.

## Why

The engine compiles each unique equation **once** (content-addressed on disk),
**color-independent** (`dvisvgm --currentcolor`, tinted at display) and
**size-independent** (scaled at display to the buffer font). So the previews do
what a browser/pandoc pipeline can't:

- **Recolor on theme switch** — flip your OS light/dark theme and previews
  re-tint straight from cache, **no LaTeX recompile**.
- **Rescale on text zoom** — `C-x C-+` / `C-x C--` re-scale the math with the
  text, again from cache.
- **Numbered equations + working `\ref` / `\eqref`** — numbered in document
  order and kept correct as you edit; references resolve to `(N)` / `N` (or
  `(??)` when the target is missing), as plain buffer text.

The engine cache is shared across every front-end (Org, Markdown,
`agent-shell-math-renderer`), so an equation compiles once across all of them.

## How detection works (and why it's markup-agnostic)

The core finds math with one **regexp scanner** — the LaTeX math delimiters are
identical across markups:

| kind    | delimiters                                        |
|---------|---------------------------------------------------|
| inline  | `$ … $`   `\( … \)`                               |
| display | `$$ … $$`   `\[ … \]`   `\begin{env} … \end{env}` |

plus bare `\eqref` / `\ref`. A **blank line always bounds a span** (LaTeX
forbids one inside), which keeps detection cheap and stops a half-typed opener
from running away.

The *only* markup-specific thing is **which regions to skip** (code, verbatim).
Each adaptor supplies that as a buffer-local `exclude-function`:

- Markdown: fenced / indented code blocks (via the `markdown` tree-sitter
  parser when present) + inline code spans.
- Org: `#+begin_src` / `example` / `export` / `comment` blocks + comment lines.

## Requirements

- Emacs 29.1+ with SVG image support (`markdown-ts-mode` needs Emacs 31.1+; the
  Org adaptor and classic `markdown-mode` work on older Emacs).
- [`latex-to-svg-backend`](https://github.com/alberti42/latex-to-svg-backend)
  0.4.0+ (the engine).
- `latex` + `dvisvgm` on `exec-path` (any TeX distribution).

## Installation

Neither repo is on MELPA yet. Register the engine and the core, then the
adaptor(s) you want — the backend is a separate repo; the frontend and adaptors
share this one (select files per package).

```elisp
;; straight
(use-package latex-to-svg-backend
  :straight (latex-to-svg-backend :type git :host github
                                  :repo "alberti42/latex-to-svg-backend"))
(use-package latex-to-svg-frontend
  :straight (latex-to-svg-frontend :type git :host github
                                   :repo "alberti42/latex-to-svg"
                                   :files ("latex-to-svg-frontend.el")))

;; Markdown
(use-package latex-to-svg-for-markdown
  :straight (latex-to-svg-for-markdown :type git :host github
                                       :repo "alberti42/latex-to-svg"
                                       :files ("latex-to-svg-for-markdown.el"))
  :hook (markdown-ts-mode . latex-to-svg-for-markdown-mode))

;; Org
(use-package latex-to-svg-for-org
  :straight (latex-to-svg-for-org :type git :host github
                                  :repo "alberti42/latex-to-svg"
                                  :files ("latex-to-svg-for-org.el"))
  :hook (org-mode . latex-to-svg-for-org-mode))
```

## Usage

Turn on the adaptor mode for your major mode:

```elisp
(add-hook 'markdown-ts-mode-hook #'latex-to-svg-for-markdown-mode)
(add-hook 'org-mode-hook         #'latex-to-svg-for-org-mode)
```

With the mode on, all math renders when the buffer opens. See
[`docs/example.md`](docs/example.md) / [`docs/example.org`](docs/example.org)
for ready-to-open demos.

- `C-c C-x C-l` (`latex-to-svg-frontend`) — toggle the fragment at point; or
  render the active region; or (failing both) the whole buffer. In Org this
  shadows the classic `org-latex-preview` while the mode is on.
- `C-u C-c C-x C-l` — **re-render** the buffer from cache (fixes a stale
  display); `C-u C-u C-c C-x C-l` — **regenerate** (recompile, bypass cache).
- `M-x latex-to-svg-frontend-clear` — clear previews (region or buffer).
- `M-x latex-to-svg-frontend-refresh` — re-tint / re-scale for the current
  theme / font from cache (also happens lazily on theme, buffer-display, and
  zoom changes).

Move point into a preview to reveal its LaTeX source for editing; leaving
re-shows the image, or re-renders if you changed the text. **Newly typed math
renders the moment the cursor leaves it** — never while you're still inside, so
half-typed equations aren't compiled.

### Per-mode configuration

The size multipliers, numbering, and detection toggles are ordinary variables
you set **buffer-locally in the mode hook** — so Org and Markdown can differ:

```elisp
(defun my/latex-to-svg-markdown-setup ()
  (setq-local latex-to-svg-frontend-inline-rescale 1.20
              latex-to-svg-frontend-display-rescale 1.25)
  (latex-to-svg-for-markdown-mode 1))
(add-hook 'markdown-ts-mode-hook #'my/latex-to-svg-markdown-setup)
```

### Delimiter toggles

Each delimiter kind can be turned off independently (all default on) —
buffer-locally in a hook, or globally. Inline and display are **separate**
toggles, so you can keep display math while silencing the error-prone inline
form:

| variable                                        | governs             |
|-------------------------------------------------|---------------------|
| `latex-to-svg-frontend-detect-dollar-inline`    | `$…$` (inline TeX)   |
| `latex-to-svg-frontend-detect-dollar-display`   | `$$…$$` (display TeX) |
| `latex-to-svg-frontend-detect-bracket-inline`   | `\(…\)` (inline LaTeX) |
| `latex-to-svg-frontend-detect-bracket-display`  | `\[…\]` (display LaTeX) |
| `latex-to-svg-frontend-detect-environments`     | `\begin{env}…\end{env}` |
| `latex-to-svg-frontend-detect-references`       | `\eqref` / `\ref`   |

**Why inline dollar is split out.** A lone `$` is the one delimiter that also
occurs in ordinary prose — prices, shell variables — so `$…$` detection can
misfire on a sentence like `the cost varies between 30$ and 50$`, turning the
span between the two dollar signs into a (broken) equation. An **escaped** `\$`
is always ignored, but neither Markdown nor Org *requires* escaping `$`, so
loose prose dollars still trip it. If that bites you, turn
**`latex-to-svg-frontend-detect-dollar-inline` off** and leave the other three
families on: `$$…$$` still renders (a doubled `$$` almost never appears by
accident), as do `\(…\)` / `\[…\]` and environments. The bracket forms are
split the same way for symmetry. (“Dollar” is plain-TeX `$`/`$$`; “bracket” /
parentheses is LaTeX `\(…\)` / `\[…\]`.)

### Numbering and cross-references

Numbered environments (`equation`, `align`, …) are numbered in document order
and stay correct as you edit (toggle with
`latex-to-svg-frontend-number-equations`). `\eqref` / `\ref` — bare or wrapped
in `$…$` — resolve against the document's `\label`s and render as **plain
buffer text** (`(3)` / `3`, in the surrounding font; `(??)` when the target is
unknown or was just deleted). Click a reference (`mouse-1`) or press `RET` to
**jump** to the defining equation. References re-resolve on every reconcile, so
they never show a stale number. See [`docs/numbering.md`](docs/numbering.md).

## Performance — what happens when you edit

Two principles keep previews responsive on large documents:

1. **LaTeX runs in the background.** Emacs never waits for a compile. The
   engine hands back a cached picture *instantly* if it has one; if not, it
   returns nothing, draws the picture in the background, and drops it in when
   ready. So even renumbering a hundred equations starts those pictures drawing
   in the background and hands control straight back to you — no freeze.
2. **The effort matches what you changed, not how big the document is.** The
   expensive passes only run when they are actually needed.

What happens, action by action:

| you… | Emacs… | cost |
|------|--------|------|
| **type inside** an equation | draws nothing (it waits — half-finished math is never sent to LaTeX) | none |
| **move the cursor out** of a *new or just-edited* equation | notices this by looking at **only the one paragraph around the cursor**; draws that equation (LaTeX in the background); then fixes the numbers of the equations **below** it by reading the previews' own ordered list, and stops as soon as the numbers line up again | grows with the number of equations *below* the edit; usually under a millisecond |
| **move the cursor out** of an equation you did *not* change | just shows its picture again | none |
| **edit without changing any equation's number** (fix a body, a label) | the number check below the edit lines up immediately and stops | ~instant |
| **paste / undo / delete** equations, or stop typing without stepping out | a fraction of a second later, one left-to-right pass over the whole buffer catches what stepping out didn't | one pass over the buffer |
| **open the buffer / render on request** | one pass over the buffer, then draw | one pass over the buffer |

Stepping out of an equation — the everyday case — never re-reads the whole
document: the equation previews are themselves a list, in document order, that
already knows each equation's number, so fixing the numbering reads that list
instead of parsing the text again. The whole-buffer pass, when it does run,
reads the buffer once from left to right (skipping code regions efficiently),
with no slow-down that grows faster than the document.

On a made-up 1000-equation / 17,000-line Markdown file, the time to settle the
numbers after leaving an edited equation went from **~1.1 s** (an early, much
slower version) down to **~6.5 ms**, and ordinary small edits are well under a
millisecond. (That time is Emacs's own work; the LaTeX pictures, when they need
redrawing, are made in the background.) Two identical equations are compiled
**once** — the on-disk cache is shared across every front-end.

## Writing an adaptor for another markup

An adaptor is a small `define-minor-mode` that sets the buffer-local protocol
and toggles the core:

- `latex-to-svg-frontend-exclude-function` — `(fn BEG END)` → list of
  `(beg . end)` regions to ignore (code / verbatim). **The one required piece.**
- `latex-to-svg-frontend-reveal-function` — `(fn)` run after a jump to unfold
  the target (Org uses `org-fold-show-context`); optional.
- `latex-to-svg-frontend-detect-function` — `(fn BEG END)` → list of math
  records, replacing the scanner entirely. Escape hatch; rarely needed.

See `latex-to-svg-for-markdown.el` / `latex-to-svg-for-org.el` (~40 lines each)
as templates.

## Status

Implemented: universal scanner with per-mode exclusions and per-kind delimiter
toggles (inline / display dollar and bracket, plus environments and references);
one overlay per element; theme / zoom refresh from cache; equation
numbering with ground-truth reconcile; `\eqref` / `\ref` resolution (incl.
`(??)` for dangling / re-resolving on rename); reveal-on-cursor editing;
render-on-leave.

Not yet: **per-keystroke renumbering** (numbers settle the moment you step out
of an equation, and a pass a fraction of a second after you stop typing covers
paste / undo / delete — but not on every keystroke while you are still inside);
`\tag`-based references and
`subequations` sub-lettering (see
[`docs/numbering.md`](docs/numbering.md)); Org inline `~code~` / `=verbatim=`
exclusion (use the toggles as a workaround).

## Tests

```sh
emacs -batch -l ert -L . -L ../latex-to-svg-backend \
      -l tests/latex-to-svg-frontend-tests.el -f ert-run-tests-batch-and-exit
```

The engine is stubbed and detection is a regexp scanner, so the suite needs no
TeX toolchain, no graphical display, and (bar one guarded fenced-code test) no
tree-sitter grammar. Point `LATEX_TO_SVG_DIR` at a `latex-to-svg-backend`
checkout if it isn't a sibling directory.

## License

GPL-3.0-or-later.
