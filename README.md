# org-latex-to-svg

Preview Org-mode LaTeX math as SVG images, on top of the
[`latex-to-svg`](https://github.com/alberti42/emacs-latex-to-svg) rendering engine.

It finds `latex-fragment` and `latex-environment` elements with `org-element`
and overlays each with an SVG typeset by `latex-to-svg`. Because the engine
renders its input **verbatim**, the front-end just passes each element's
`:value` (delimiters / `\begin{…}…\end{…}` and all) — no stripping, no
wrapping; inline vs display sizing follows from the delimiters.

## Why not built-in `org-latex-preview`?

The engine compiles each unique equation **once** (content-addressed on disk),
**color-independent** (`dvisvgm --currentcolor`, tinted at display) and
**size-independent** (scaled at display to the buffer font). So this front-end
gets, for free, what built-in Org's classic preview cannot do:

- **Recolor on theme switch** — flip your OS light/dark theme and previews
  re-tint straight from cache, **no LaTeX recompile**.
- **Rescale on text zoom** — `C-x C-+` / `C-x C--` re-scale the math with the
  text, again from cache.

The shared cache is also used by any other `latex-to-svg` front-end (e.g.
`agent-shell-math-renderer`), so an equation compiles once across all of them.

## Requirements

- Emacs 29.1+ with SVG image support.
- [`latex-to-svg`](https://github.com/alberti42/emacs-latex-to-svg) 0.3.1+ (the
  rendering engine; repo `alberti42/emacs-latex-to-svg`).
- `latex` + `dvisvgm` on `exec-path` (any TeX distribution).

## Installation

Neither package is on MELPA yet, so install both from their repositories.
`latex-to-svg` is a hard dependency — declare it **before** `org-latex-to-svg`
so it is on `load-path` when the latter's `(require 'latex-to-svg)` runs.

```elisp
;; use-package + :vc (Emacs 30+)
(use-package latex-to-svg
  :vc (:url "https://github.com/alberti42/emacs-latex-to-svg" :rev :newest))
(use-package org-latex-to-svg
  :vc (:url "https://github.com/alberti42/org-latex-to-svg" :rev :newest)
  :after (org latex-to-svg)
  :hook (org-mode . org-latex-to-svg-mode))

;; use-package + straight
(use-package latex-to-svg
  :straight (latex-to-svg :type git :host github
                          :repo "alberti42/emacs-latex-to-svg"))
(use-package org-latex-to-svg
  :straight (org-latex-to-svg :type git :host github
                             :repo "alberti42/org-latex-to-svg")
  :after (org latex-to-svg)
  :hook (org-mode . org-latex-to-svg-mode))

;; elpaca
(elpaca (latex-to-svg :host github :repo "alberti42/emacs-latex-to-svg"))
(elpaca (org-latex-to-svg :host github :repo "alberti42/org-latex-to-svg"))
```

## Usage

```elisp
(add-hook 'org-mode-hook #'org-latex-to-svg-mode)
```

With the mode on, all fragments/environments render when the buffer opens.

See [`docs/example.org`](docs/example.org) for a ready-to-open demo of inline /
display math, automatic numbering, `\eqref` cross-references, and
reveal-on-cursor editing.

- `C-c C-x C-l` (`org-latex-to-svg`) — toggle the fragment at point; or render
  the active region; or (failing both) the whole buffer. This shadows Org's
  classic `org-latex-preview` on the same key while the mode is on.
- `C-u C-c C-x C-l` — **re-render** the buffer (clear then render; rebuilds
  overlays from cache — fixes a stale display).
- `C-u C-u C-c C-x C-l` — **regenerate** the buffer: a fresh recompile that
  bypasses the cache (see `org-latex-to-svg-regenerate`), for a stale/corrupt
  cached SVG.
- `M-x org-latex-to-svg-clear` — clear previews (region or buffer), revealing
  source. (Turning off `org-latex-to-svg-mode` also clears.)
- `M-x org-latex-to-svg-refresh` — re-tint / re-scale existing previews for the
  current theme / font size from cache (previews also refresh lazily on theme,
  buffer-display, and zoom changes).

Move point into a preview to reveal its LaTeX source for editing; leaving
re-shows the image, or re-renders it if you changed the text. This applies to
`\eqref` / `\ref` references too — arrow into one to edit its label, and it
re-renders to the new target's number on leave.

### Numbering and cross-references

Numbered environments (`equation`, `align`, …) are numbered in document order
(`(1)`, `(2)`, …) and stay correct as you edit; toggle with
`org-latex-to-svg-number-equations`. `\eqref` / `\ref` are resolved against the
document's `\label`s and drawn as plain buffer text (`(3)` / `3`, in the
surrounding font — not a LaTeX image). Click a reference (`mouse-1`) or press
`RET` on it to **jump** to the equation defining its label.

### Cache note

The engine caches each equation by content hash (`LaTeX + preamble`), so a
matching render is trusted and never recompiled — repeats are instant. If you
ever see a genuinely stale or corrupt image, `org-latex-to-svg-regenerate`
(or `C-u C-u C-c C-x C-l`) deletes those SVGs and recompiles.

## Status

Implemented:

- Renders on mode-enable and on demand; theme / zoom refresh from cache.
- **Equation numbering** in document order, kept correct across edits via a
  debounced reconcile that uses the engine's ground-truth counter metadata.
- **`\eqref` / `\ref`** resolved to plain buffer text and click-to-jump to the
  equation defining the label.
- **Reveal-on-cursor editing** — move point into a preview (image or reference)
  to reveal and edit its source; it re-renders on leave. A mouse click on a
  reference is a jump, not an edit.

Not yet:

- **Live renumber while typing** — numbers refresh when the edited block (or a
  covering region / buffer) is next rendered, not on every keystroke.
- `\tag`-based references and `subequations` (see [`docs/numbering.md`](docs/numbering.md)).

## Tests

```sh
emacs -batch -l ert -l tests/org-latex-to-svg-tests.el -f ert-run-tests-batch-and-exit
```

The engine is stubbed, so the suite needs no TeX toolchain or graphical
display. Point `LATEX_TO_SVG_DIR` at a `latex-to-svg` checkout if it isn't a
sibling directory.

## License

GPL-3.0-or-later.
