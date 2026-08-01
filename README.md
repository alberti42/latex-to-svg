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
- [`latex-to-svg`](https://github.com/alberti42/emacs-latex-to-svg) 0.2.0+.
- `latex` + `dvisvgm` on `exec-path` (any TeX distribution).

## Usage

```elisp
(add-hook 'org-mode-hook #'org-latex-to-svg-mode)
```

With the mode on, all fragments/environments render when the buffer opens.

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

Editing the text under a preview clears it, revealing the source.

### Cache note

The engine caches each equation by content hash (`LaTeX + preamble`), so a
matching render is trusted and never recompiled — repeats are instant. If you
ever see a genuinely stale or corrupt image, `org-latex-to-svg-regenerate`
(or `C-u C-u C-c C-x C-l`) deletes those SVGs and recompiles.

## Status (v0.1)

- Renders on mode-enable and on demand; theme/zoom refresh from cache; clears
  on edit.
- **Not yet:** reveal-on-cursor-enter (edit without first clearing) and
  equation **numbering** — numbered environments currently show the standalone
  `(1)`. Numbering + `\eqref` resolution (via a `label → number` map and a
  `\setcounter` injected into the per-fragment LaTeX, which folds into the
  engine's content hash) is a planned milestone.

## Tests

```sh
emacs -batch -l ert -l tests/org-latex-to-svg-tests.el -f ert-run-tests-batch-and-exit
```

The engine is stubbed, so the suite needs no TeX toolchain or graphical
display. Point `LATEX_TO_SVG_DIR` at a `latex-to-svg` checkout if it isn't a
sibling directory.

## License

GPL-3.0-or-later.
