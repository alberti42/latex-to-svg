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

![`docs/example.md` in `markdown-ts-mode`: rendered display equations, per-line equation numbers, click-to-jump `\ref`/`\eqref` links, and reveal-on-cursor showing the `\label` source at point.](Screenshot.png)

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
- **Math source is shielded from stray emphasis fontifying** — markup
  font-lock has no idea what LaTeX is, so it happily reads `(+)` as
  strike-through, `_i` as underline, `*x*` as bold, `/x/` as italic and
  decorates your equation (a line struck clean through the rendered SVG, even).
  Stock Org LaTeX preview has no defense against this. Here the same detector
  that finds math also neutralizes those attributes over it — on the rendered
  overlay **and** on the raw source while you edit — so `*`, `/`, `_`, `+` are
  treated as the LaTeX syntax they are. Prose emphasis outside math is
  untouched; toggle with `latex-to-svg-frontend-suppress-emphasis`.

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

- Markdown: inline code spans (a backtick regexp) plus, when the `markdown`
  tree-sitter grammar is installed, fenced / indented code blocks. The adaptor
  runs the same in `markdown-ts-mode` **or** classic `markdown-mode` /
  `gfm-mode` — it uses the `markdown` grammar directly (reusing the buffer's
  parser if there is one, else creating its own), so the grammar is an optional
  accelerator for block code, not a dependency on the major mode.
- Org: `#+begin_src` / `example` / `export` / `comment` blocks + comment lines.

## Requirements

- Emacs 29.1+ with SVG image support. The Markdown adaptor works under
  `markdown-ts-mode` (Emacs 31.1+) **or** classic `markdown-mode` / `gfm-mode`;
  the `markdown` tree-sitter grammar is optional (it adds fenced/indented
  code-block exclusion — inline code is handled without it).
- [`latex-to-svg-backend`](https://github.com/alberti42/latex-to-svg-backend)
  0.4.0+ (the engine).
- `latex` + `dvisvgm` on `exec-path` (any TeX distribution).

## Installation

Neither repo is on MELPA yet. The stack has three layers, installed bottom-up:

- **`latex-to-svg-backend`** — the LaTeX → SVG compile engine, in its own repo.
- **`latex-to-svg-frontend`** — the shared preview core (detection, overlays,
  numbering, refresh), markup-agnostic.
- **`latex-to-svg-for-markdown`** / **`latex-to-svg-for-org`** — the per-mode
  adaptors. Install whichever you use; both are optional.

The frontend and the two adaptors live in one repo (this one), so their recipes
select a single file each; the backend is a separate repo.

### Straight

```elisp
;; Backend — the LaTeX -> SVG engine (separate repo)
(use-package latex-to-svg-backend
  :straight (latex-to-svg-backend :type git :host github
                                  :repo "alberti42/latex-to-svg-backend"))

;; Frontend — the shared preview core
(use-package latex-to-svg-frontend
  :straight (latex-to-svg-frontend :type git :host github
                                   :repo "alberti42/latex-to-svg"
                                   :files ("latex-to-svg-frontend.el"))
  ;; Optional: re-tint previews the instant you switch themes.
  ;; See "Refreshing on appearance changes" below; omit if you never
  ;; change themes at runtime.
  :config
  (add-hook 'enable-theme-functions
            #'latex-to-svg-frontend-on-theme-change))

;; Markdown adaptor
(use-package latex-to-svg-for-markdown
  :straight (latex-to-svg-for-markdown :type git :host github
                                       :repo "alberti42/latex-to-svg"
                                       :files ("latex-to-svg-for-markdown.el"))
  :hook (markdown-ts-mode . latex-to-svg-for-markdown-mode))

;; Org adaptor
(use-package latex-to-svg-for-org
  :straight (latex-to-svg-for-org :type git :host github
                                  :repo "alberti42/latex-to-svg"
                                  :files ("latex-to-svg-for-org.el"))
  :hook (org-mode . latex-to-svg-for-org-mode))
```

## Usage

Turn on the adaptor mode for your major mode (the Markdown adaptor also works
in classic `markdown-mode` / `gfm-mode` — hook whichever you use):

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

The size multipliers, colors, numbering, and detection toggles are ordinary
variables you set **buffer-locally in the mode hook** — so Org and Markdown can
differ:

```elisp
(defun my/latex-to-svg-markdown-setup ()
  (setq-local latex-to-svg-frontend-inline-rescale 1.20
              latex-to-svg-frontend-display-rescale 1.25)
  (latex-to-svg-for-markdown-mode 1))
(add-hook 'markdown-ts-mode-hook #'my/latex-to-svg-markdown-setup)
```

### Colors and box

By default previews use the buffer foreground (so they track your theme) on a
transparent background. You can override any of three appearance options — they
apply instantly from cache (no recompiling); after changing one, run `M-x
latex-to-svg-frontend-refresh`:

| Option | Default | Description |
|--------|---------|-------------|
| `latex-to-svg-frontend-foreground-color` | `nil` | Fixed ink color; `nil` follows the buffer foreground (tracks the theme). |
| `latex-to-svg-frontend-background-color` | `nil` | Box color behind previews; `nil` is transparent. A very light gray reads best (e.g. `gray97` / `#f7f7f7`). |
| `latex-to-svg-frontend-background-padding` | `nil` | Padding (pt) between the equation and the box edge; only visible with a background color. `nil`/`0` crops to the ink. |

### Refreshing on appearance changes

Previews track the buffer colors and font and re-render automatically when they
change. `latex-to-svg-frontend-mode` installs its refresh triggers
**buffer-locally** when enabled (never merely by loading the package):
redisplay (`window-buffer-change-functions`) and zoom (`text-scale-mode-hook`),
so an inactive buffer costs nothing and they are removed when the mode is off.

A theme switch is a *global* event, with no per-buffer hook, so the package
installs nothing global on your behalf. If you want previews to re-tint the
instant you switch themes, add the provided function to `enable-theme-functions`
yourself — the same way you enable the mode:

```elisp
(add-hook 'enable-theme-functions #'latex-to-svg-frontend-on-theme-change)
```

Without it, previews re-tint on their next redisplay. You can always force a
refresh with `M-x latex-to-svg-frontend-refresh`.

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
occurs in ordinary prose — prices, shell variables. The scanner already guards
the common cases (pandoc-style: an opening `$` must be followed by a non-space
character, a closing `$` preceded by one, and an escaped `\$` is ignored), so
spaced currency like `$30 and $50` is **not** mistaken for math. What still
slips through is a no-space range like `$100-$200`: the hyphen touches both
dollars, so it reads as the equation `100-` and the rest of the line is
mangled. This case is *irreducible* — `$100-$200` is syntactically identical to
legitimate math such as `$x$2`, so no local rule can reject one without the
other.

Two ways to deal with it:

- **One-off:** escape the dollars — `\$100-\$200` — which the scanner ignores.
- **Document-wide:** if a buffer is full of prices, turn
  **`latex-to-svg-frontend-detect-dollar-inline` off** and write your math with
  the unambiguous LaTeX parentheses form `\(…\)` instead. The other three
  families keep working: `$$…$$` (a doubled `$$` almost never appears by
  accident), `\(…\)` / `\[…\]`, and environments.

The bracket forms are split the same way for symmetry. (“Dollar” is plain-TeX
`$`/`$$`; “bracket” / parentheses is LaTeX `\(…\)` / `\[…\]`.)

### Numbering and cross-references

Numbered environments (`equation`, `align`, …) are numbered in document order
and stay correct as you edit (toggle with
`latex-to-svg-frontend-number-equations`). `\eqref` / `\ref` — bare or wrapped
in `$…$` — resolve against the document's `\label`s and render as **plain
buffer text** (`(3)` / `3`, in the surrounding font; `(??)` when the target is
unknown or was just deleted). Click a reference (`mouse-1`, or `mouse-2`) or
press `C-c C-o` to **jump** to the defining equation — the standard Emacs link
gesture, honouring `mouse-1-click-follows-link`. Move point in with the
*keyboard* to see the `\eqref{…}` source instead.

`RET` is left alone, because the buffer is editable and the preview's keymap is
already active with point at the reference's *first* character — binding it
there would make a line like `  \eqref{eq:test}  ` impossible to break before
the reference. Set `latex-to-svg-frontend-return-follows-reference` to `t` if
you want it anyway; it is the markup-agnostic analogue of Org's
`org-return-follows-link` (also `nil` by default), and applies in every markup.

References re-resolve on every reconcile, so
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

To add math previews for a major mode that isn't covered yet, write an adaptor.
The math logic lives in the core; an adaptor only supplies what counts as
"code" in that markup. It's a small `define-minor-mode` that sets the
buffer-local protocol and toggles the core:

- `latex-to-svg-frontend-exclude-function` — `(fn BEG END)` → list of
  `(beg . end)` regions to ignore (code / verbatim). **The one required piece.**
- `latex-to-svg-frontend-reveal-function` — `(fn)` run after a jump to unfold
  the target (Org uses `org-fold-show-context`); optional.
- `latex-to-svg-frontend-detect-function` — `(fn BEG END)` → list of math
  records, replacing the scanner entirely. Escape hatch; rarely needed.

See `latex-to-svg-for-markdown.el` / `latex-to-svg-for-org.el` (~40 lines each)
as templates.

Pull requests adding adaptors for other major modes are welcome.

## Limitations

- **`\tag`-based references and `subequations` sub-lettering** aren't modelled
  (see [`docs/numbering.md`](docs/numbering.md)).
- **Org inline `~code~` / `=verbatim=` aren't excluded** — a math delimiter
  written inside them is still detected and previewed (Org block code —
  `#+begin_src` / `example` / … — and comment lines *are* excluded; only
  inline code / verbatim isn't yet).

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
