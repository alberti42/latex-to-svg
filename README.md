# latex-to-svg

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![MELPA](https://melpa.org/packages/latex-to-svg-frontend-badge.svg)](https://melpa.org/#/latex-to-svg-frontend)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-frontend-badge.svg)](https://stable.melpa.org/#/latex-to-svg-frontend)
[![melpazoid](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg)](LICENSE)

Render LaTeX math in Emacs Org, Markdown and LaTeX buffers. Inline and display math,
numbered environments included, is compiled with
[LaTeX](https://www.latex-project.org/) (`latex` → `dvisvgm`), or with
[RaTeX](https://github.com/erweixin/RaTeX), by the
[`latex-to-svg-backend`](https://github.com/alberti42/latex-to-svg-backend)
backend, into SVG images that match the theme. Each image is a display overlay
on top of its LaTeX source, which stays in the buffer: when the cursor moves
into an equation, the overlay shows the source for editing, and when the
cursor leaves it, the equation is rendered again.

This repo is the **front-end**: a shared core plus thin per-mode adaptors.

- **`latex-to-svg-frontend`** — the core: math detection, overlay lifecycle,
  equation numbering, `\ref`/`\eqref` resolution, reveal-on-cursor editing,
  render-on-leave, and theme/zoom refresh. Knows nothing about any markup.
- **`latex-to-svg-for-markdown`** — [Markdown adaptor](docs/latex-to-svg-for-markdown.md).
- **`latex-to-svg-for-org`** — [Org adaptor](docs/latex-to-svg-for-org.md).
- **`latex-to-svg-for-latex`** — [LaTeX adaptor](docs/latex-to-svg-for-latex.md).
- **`latex-to-svg-for-gnus`** — [Gnus adaptor](docs/latex-to-svg-for-gnus.md).

An overview of the adaptors is presented under [One adaptor per markup](#one-adaptor-per-markup).

```
  latex-to-svg-for-markdown ─┐
  latex-to-svg-for-org ──────┤
  latex-to-svg-for-latex ────┼─▶ latex-to-svg-frontend ─▶ latex-to-svg-backend
  latex-to-svg-for-gnus ─────┘        (this repo)             (backend)
```

You install an **adaptor**; it pulls in the frontend core and the backend
as dependencies.

![`docs/example.org` in Org mode: numbered equations, Maxwell's equations numbered per row, click-to-jump `\eqref` references shown as their numbers, and a `#+begin_comment` block left as text.](Screenshot-Org.png)

## Why

The backend compiles each unique equation **once** (content-addressed on disk),
**color-independent** (tinted at display, with either engine) and
**size-independent** (scaled at display to the font of the text it is in). So the previews do
what a browser/pandoc pipeline can't:

- **Recolor on theme switch** — flip your OS light/dark theme and previews
  re-tint straight from cache, **no recompile**.
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

The backend cache is shared across every front-end (Org, Markdown,
`agent-shell-math-renderer`), so an equation compiles once across all of them.

## Related packages

This repo is one layer of a three-part stack, and one of two front-ends built
on the same backend:

- [**`latex-to-svg-backend`**](https://github.com/alberti42/latex-to-svg-backend)
  — the backend: one LaTeX string in, one image out, with the
  content-addressed on-disk cache, `--currentcolor` tinting, display scaling and
  the compile-metadata sidecar that numbering reads.
- **`latex-to-svg`** (this repo) — the markup front-end: detection, overlays,
  numbering, `\ref` / `\eqref`, refresh. For Org it is a drop-in replacement for
  the built-in `org-latex-preview`.
- [**`agent-shell-math-renderer`**](https://github.com/alberti42/agent-shell-math-renderer)
  — the sibling front-end, rendering math in
  [`agent-shell`](https://github.com/xenodium/agent-shell)'s streamed markdown
  output. Same backend, same cache: an equation that appears both in your Org
  notes and in an agent's reply compiles only once.

Equations in a table cell are drawn in the tables of
[`pretty-tables`](https://github.com/alberti42/pretty-tables.el), which
aligns and wraps Markdown and Org tables: each image carries its width in
pixels as `:width`, which pretty-tables reads, and the table is drawn again
when an image in it is shown.

Several other Emacs packages preview LaTeX math — the built-in Org
`org-latex-preview` and the tecosaur/karthink fork of it, AUCTeX's
`preview-latex`, `texfrag`, `org-latex-impatient`, `org-xlatex`,
`latex-math-preview`. A **detailed comparison** of how they render, what they
are tied to, and which of them recolor from cache or support numbering and
cross-references lives in the backend's README, under
[Related packages](https://github.com/alberti42/latex-to-svg-backend#related-packages)
— rather than repeat it here.

## One adaptor per markup

The core knows nothing about any markup. An adaptor tells it which regions of
a buffer are code, verbatim or comment, so math inside them is not previewed,
and turns the core on. Install the adaptor for each markup you use; its page
gives the recipe, the hook and the details.

### `latex-to-svg-for-markdown`

[![MELPA](https://melpa.org/packages/latex-to-svg-for-markdown-badge.svg)](https://melpa.org/#/latex-to-svg-for-markdown)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-for-markdown-badge.svg)](https://stable.melpa.org/#/latex-to-svg-for-markdown)

For `markdown-ts-mode` (Emacs 31.1+) or classic `markdown-mode` / `gfm-mode`.
Skips inline code spans, fenced code blocks and indented code blocks. The
`markdown` tree-sitter grammar is optional: it makes code-block exclusion
exact; without it a regexp fallback handles fenced and indented blocks. See
[its page](docs/latex-to-svg-for-markdown.md).

### `latex-to-svg-for-org`

[![MELPA](https://melpa.org/packages/latex-to-svg-for-org-badge.svg)](https://melpa.org/#/latex-to-svg-for-org)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-for-org-badge.svg)](https://stable.melpa.org/#/latex-to-svg-for-org)

For `org-mode`. Skips `#+begin_src` / `example` / `export` / `comment` blocks,
comment lines, table formulas (`#+TBLFM:`), fixed-width lines (`: …`) and
inline `~code~` / `=verbatim=` spans. While it is on,
`org-latex-preview` only says that it is off: Org's preview would draw its own
images over these. See [its page](docs/latex-to-svg-for-org.md).

### `latex-to-svg-for-latex`

[![MELPA](https://melpa.org/packages/latex-to-svg-for-latex-badge.svg)](https://melpa.org/#/latex-to-svg-for-latex)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-for-latex-badge.svg)](https://stable.melpa.org/#/latex-to-svg-for-latex)

For AUCTeX's `LaTeX-mode` or the built-in `latex-mode`. Skips comments,
`comment` environments, `\iffalse` … `\fi`, verbatim environments and `\verb`,
and the preamble. `\ref` and `\eqref` show the numbers LaTeX printed, read from
the document's `.aux` file, so references to sections, figures and other files
resolve too. While it is on, AUCTeX's preview-latex commands only say that they
are off. See [its page](docs/latex-to-svg-for-latex.md).

### `latex-to-svg-for-gnus`

Not on MELPA yet.

For Gnus's `gnus-article-mode`, such as the abstracts of the arXiv feeds on
gwene.org. Skips nothing. Draws the previews again for each article Gnus
shows, turns equation numbering off in the article buffer, and removes Gnus's
emphasis from inside math. See [its page](docs/latex-to-svg-for-gnus.md).

To add an adaptor for another markup, see
[Writing an adaptor for another markup](#writing-an-adaptor-for-another-markup).

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
Each adaptor supplies that as a buffer-local `exclude-function`; its page lists
what it skips (see [One adaptor per markup](#one-adaptor-per-markup)).

## Requirements

- Emacs 29.1+ with SVG image support. Each adaptor's page lists the major
  modes it works in (see [One adaptor per markup](#one-adaptor-per-markup)).
- [`latex-to-svg-backend`](https://github.com/alberti42/latex-to-svg-backend)
  0.14.0+ (the backend) — the floor is set by 0.14.0, which reads no faces
  and no frames: the front-end passes the colors and the font size it reads
  on the frame that shows the buffer, as `#rrggbb` strings and as
  `:font-size`, the em of the text in pixels. With 0.14.0 each image has
  `:width` in pixels, which pretty-tables reads, and an inline equation sits
  on the text's baseline. `latex-to-svg-backend-image-width` came with
  0.13.0. The `texres` engine came
  with 0.12.0 together with the backend's warning for a program that is not
  found; 0.12.1 fixed the texres engine on Emacs 29 to 31. The per-project
  preambles came with 0.11.1: the
  backend reads `latex-to-svg-backend-preamble`, `-appended-preamble` and
  `-preamble-not-precompiled` in the buffer that asks for an equation, and the
  front-end watches all three, so that setting one updates the previews. The engine
  choice (`:engine`, behind `latex-to-svg-frontend-engine` and the
  `% engine=` cookie), the LaTeX fallback and quiet failures (`:fallback` /
  `:quiet`, behind `latex-to-svg-frontend-fallback` and `-quiet`), and
  `latex-to-svg-backend-engine-used`, which the tooltip uses to name the
  engine, came with 0.10.0. The display-time `:color` / `:background` /
  `:padding` overrides came earlier.
- `latex` + `dvisvgm` on `exec-path` (any TeX distribution), or RaTeX's
  `render-svg` for the `ratex` engine, or texres and `pdftocairo` for the
  `texres` engine (see [Engine](#engine)).

## Installation

The stack has three layers:

- **[`latex-to-svg-backend`](https://melpa.org/#/latex-to-svg-backend)** — the
  backend, which compiles LaTeX to SVG.
- **[`latex-to-svg-frontend`](https://melpa.org/#/latex-to-svg-frontend)** — the
  shared preview core (detection, overlays, numbering, refresh),
  markup-agnostic.
- **`latex-to-svg-for-markdown`** / **`latex-to-svg-for-org`** /
  **`latex-to-svg-for-latex`** / **`latex-to-svg-for-gnus`** — the per-mode
  adaptors. Install whichever you
  use.

Install the adaptor for each markup you use; it pulls in the frontend and the
backend through its `Package-Requires` header. The Markdown, Org and LaTeX
adaptors are on MELPA, with `melpa` in `package-archives`:

```elisp
(use-package latex-to-svg-for-org
  :ensure t
  :hook (org-mode . latex-to-svg-for-org-mode)
  :init
  ;; Ignore `#+startup: latexpreview': it would run Org's own preview
  ;; before this mode turns on (see Troubleshooting in
  ;; docs/latex-to-svg-for-org.md).
  (with-eval-after-load 'org
    (setq org-startup-options
          (assoc-delete-all "latexpreview" org-startup-options))))
```

With `straight`, which resolves MELPA recipes on its own, write `:straight t`
instead of `:ensure t` (run `M-x straight-pull-recipe-repositories` if your
recipes predate the packages). Each adaptor's page gives its lines
([Markdown](docs/latex-to-svg-for-markdown.md#installation),
[Org](docs/latex-to-svg-for-org.md#installation),
[LaTeX](docs/latex-to-svg-for-latex.md#installation)). The Gnus adaptor is
not on MELPA yet: its page gives a git recipe
([Gnus](docs/latex-to-svg-for-gnus.md#installation)).

Optionally, re-tint previews the instant you switch themes, and rescale them
when the frame font changes (see
[Refreshing on appearance changes](#refreshing-on-appearance-changes); omit
this if you never change themes or font sizes at runtime):

```elisp
(with-eval-after-load 'latex-to-svg-frontend
  (add-hook 'enable-theme-functions
            #'latex-to-svg-frontend-on-appearance-change)
  (add-hook 'after-setting-font-hook
            #'latex-to-svg-frontend-on-appearance-change))
```

## Usage

Turn on the adaptor mode from your major mode's hook; each adaptor's page gives
the line. With the mode on, all math renders when the buffer opens. See
[`docs/example.md`](docs/example.md) / [`docs/example.org`](docs/example.org) /
[`docs/example.tex`](docs/example.tex) for ready-to-open demos.

- `M-x latex-to-svg-frontend-clear` — clear previews (region or buffer).
- `M-x latex-to-svg-frontend-refresh` — bring the current buffer's previews up
  to date: render equations that have none (except the one the cursor is in),
  render again those whose engine changed, and redraw the rest from cache for
  the current theme, font, colors and size. You rarely need it: setting an
  option of this package, or one of the backend options listed there (with
  `setq`, `setq-local` or Customize), updates the previews on its own (see
  [Changing an option](#changing-an-option)) — every buffer for a global value, one buffer for a
  buffer-local one — and redrawing happens on its own on theme,
  buffer-display and zoom changes. Run it after a change those cannot see,
  such as a backend option (`latex-to-svg-backend-font-scale`).
  With a prefix argument (`C-u M-x latex-to-svg-frontend-refresh`), it
  **recompiles** the current buffer's previews instead, bypassing the cache.
  When an equation is typeset with LaTeX, it also deletes the buffer's `.fmt`
  file, which the next compile dumps again: run it after editing a file the
  preamble loads, such as the `macros.tex` of an `\input{macros.tex}`.
  Either way it touches only the current buffer.

Move point into a preview to reveal its LaTeX source for editing; leaving
re-shows the image, or re-renders if you changed the text. **Newly typed math
renders the moment the cursor leaves it** — never while you're still inside, so
half-typed equations aren't compiled. Math you paste, yank or restore with an
undo renders a moment later (`latex-to-svg-frontend-reconcile-idle`, 0.4 s),
except an equation the cursor is in.

`latex-to-svg-frontend-reveal` sets when the preview point is on is shown as
its LaTeX source: `always`, `writable` (default; in a buffer that is not
read-only) or `nil` (never). During an Isearch it is shown whatever the value.

### Per-mode configuration

The size multipliers, colors, numbering, and detection toggles are ordinary
variables you set **buffer-locally in the mode hook** — so Org and Markdown can
differ:

```elisp
(defun my/latex-to-svg-markdown-setup ()
  (setq-local latex-to-svg-frontend-rescale-inline 1.20
              latex-to-svg-frontend-rescale-display 1.25)
  (latex-to-svg-for-markdown-mode 1))
(add-hook 'markdown-ts-mode-hook #'my/latex-to-svg-markdown-setup)
```

### Changing an option

These options update the previews on their own when you set them, with `setq`,
`setq-local`, `.dir-locals.el` or Customize:

| Option | What is redone |
|--------|----------------|
| `latex-to-svg-frontend-engine` | the equations are typeset again with the new engine |
| `latex-to-svg-frontend-fallback` | the equations RaTeX rejected are typeset again, or left as text |
| `latex-to-svg-frontend-foreground-color`, `-background-color`, `-padding-inline`, `-padding-display` | the pictures are redrawn from cache |
| `latex-to-svg-frontend-rescale-inline`, `-rescale-display` | the pictures are redrawn from cache |
| `latex-to-svg-frontend-center-display-math` | the pictures are redrawn from cache |
| `latex-to-svg-backend-preamble`, `-appended-preamble`, `-preamble-not-precompiled` | the equations are compiled with the new preamble, or taken from cache if compiled with it before |
| `latex-to-svg-backend-line-width` | the numbered equations are compiled with the new width, or taken from cache if compiled with it before |
| `latex-to-svg-backend-ratex-macros` | the equations typeset with RaTeX are compiled with the new macros, or taken from cache if compiled with them before |

Where the change applies depends on how you make it:

- **A global value** (`setq` of a variable with no buffer-local value,
  `setq-default`, Customize) updates **every open buffer** with previews.
- **A buffer-local value** (`setq-local`, `.dir-locals.el`) updates only that
  buffer.
- **A `let`-binding** updates nothing.

Redrawing from cache is instant. A new engine typesets from cache every
equation it has compiled before; the others compile, in about 6 ms each with
RaTeX and about 300 ms each with LaTeX. So to try LaTeX on one troublesome
document without re-typesetting everything else, set the engine buffer-locally
in that buffer — `M-: (setq-local latex-to-svg-frontend-engine 'latex)` — or
use a cookie for a single equation (see [Engine](#engine)).

Other options apply to equations rendered afterwards.

### Projects with their own macros

Equations that use a project's own macros or packages fail with the backend's
default preamble. Set the project's preamble in its `.dir-locals.el`, in one of
two backend options:

- `latex-to-svg-backend-appended-preamble` is dumped into a `.fmt` file, one
  per project: the place for packages, which it then reads once.
- `latex-to-svg-backend-preamble-not-precompiled` is written into every
  compile and adds no `.fmt` file: enough for macros.

For a file of macros, `\input` it:

```elisp
((nil . ((latex-to-svg-backend-preamble-not-precompiled . "\\input{macros.tex}"))))
```

Every backslash is doubled, as in any Elisp string. `\input` finds the file in
the project root (`project-root`), or in `default-directory` outside a
project. To make the directory holding `.dir-locals.el` a project root, set
`project-vc-extra-root-markers` to `'(".dir-locals.el")`.

Both options are LaTeX code, so Emacs asks before applying them from
`.dir-locals.el`, and answering `!` trusts only that exact value: the next
edit of the string asks again. For a project you started or otherwise trust,
list its directory, the one holding `.dir-locals.el`, in
`safe-local-variable-directories` (Emacs 30.1+). Emacs then applies that
`.dir-locals.el` without asking, whatever it sets:

```elisp
(add-to-list 'safe-local-variable-directories
             (expand-file-name "~/papers/thesis/"))
```

The backend README's
[A project's preamble](https://github.com/alberti42/latex-to-svg-backend#a-projects-preamble)
compares the two options and gives the details.

This package follows the setting:

- The first render of a file waits until its `.dir-locals.el` is applied, and
  setting either option updates the previews (see
  [Changing an option](#changing-an-option)).
- **After editing `macros.tex`**, run `C-u M-x latex-to-svg-frontend-refresh`:
  it deletes the buffer's `.fmt` file and compiles its equations again. It does
  this for the current buffer only; other open files of the project need their
  own.
- The `ratex` engine has no preamble. An equation that uses a project macro
  fails with RaTeX and, with `latex-to-svg-frontend-fallback` on (the default),
  is typeset by LaTeX. If you set `latex-to-svg-frontend-engine` to `ratex`,
  set it back to `latex` for such a project, in the same `.dir-locals.el`;
  Emacs applies that value without asking.

### Engine

`latex-to-svg-frontend-engine` chooses the program that typesets the
previews:

| Value | Program | Typesets |
|-------|---------|----------|
| `latex` (default) | `latex` + `dvisvgm` | Full LaTeX, with any package the backend's preamble loads. |
| `ratex` | RaTeX's `render-svg` | The math KaTeX supports, with no packages and no TeX installation. |
| `texres` | the `pdflatex` of [texres](https://github.com/leoliu0/texres) + `pdftocairo` | Full LaTeX, with the LaTeX engine's preamble options, and no TeX Live installation. |

The choice is passed to the backend with each equation. Where the programs
are is a backend setting (`latex-to-svg-backend-latex-program`,
`latex-to-svg-backend-ratex-program`, `latex-to-svg-backend-texres-program`);
the backend README's
[Engines](https://github.com/alberti42/latex-to-svg-backend#engines)
section covers installing RaTeX and texres and what changes with each. The option is safe
as a file- or directory-local variable, so a project can choose RaTeX in its
`.dir-locals.el`:

```elisp
((nil . ((latex-to-svg-frontend-engine . ratex))))
```

Each engine has its own cache entries. Setting the option renders again the
equations it affects, on its own.

What works with `ratex`:

- **Numbering and references work.** RaTeX has no equation counter, so each
  numbered row gets its number as `\tag{N}`, and `\label` is removed from
  what RaTeX receives. The numbers come from the front-end's own count of
  rows (see [`docs/numbering.md`](docs/numbering.md)).
- **Environments:** `equation`, `align`, `alignat`, `gather`, and their starred
  forms. RaTeX does not have `multline`, `eqnarray`, `flalign` and the other
  environments LaTeX offers; LaTeX typesets those instead (see the fallback
  below), or a `% engine=latex` cookie sends one such equation to LaTeX.
- **An `\eqref` or `\ref` inside an equation fails** in RaTeX (`a = b \text{
  by } \eqref{x}`). A reference in the prose is drawn as buffer text and
  works.

Hovering over a preview shows which engine typeset it, then its source:
"Typeset with RaTeX: \[ E=mc^2 \]".

What works with `texres`: the same as with `latex`. Numbering uses LaTeX's own
counter, `C-u M-x latex-to-svg-frontend-refresh` deletes texres's `.fmt` file
too, and in LaTeX buffers a global `texres` stays (see the
[LaTeX adaptor](docs/latex-to-svg-for-latex.md)). An equation texres rejects
has a LaTeX error, so `latex-to-svg-frontend-fallback` does not apply: its
source stays as text.

#### When RaTeX cannot typeset an equation

RaTeX has no packages, so an equation using siunitx's `\SI`,
`\DeclareMathOperator` or an environment RaTeX lacks fails there. With
`latex-to-svg-frontend-fallback` on (the default), LaTeX typesets such an
equation instead, and the backend records the failure, so the next time the
LaTeX picture comes straight from the cache.

- **The styles differ.** A fallback equation is typeset in LaTeX's style
  (Computer Modern) next to RaTeX's (KaTeX's fonts). The tooltip of a
  fallback equation says why: "Typeset with LaTeX (RaTeX could not parse
  it): …", and the backend reports once per buffer how many equations fell
  back.
- **A fallback equation compiles in about 300 ms**, a RaTeX one in about
  6 ms.
- **The fallback needs `latex` and `dvisvgm`.** Without them the backend
  warns once per session; install them, or set
  `latex-to-svg-frontend-fallback` to nil. With the fallback off, an
  equation RaTeX rejects keeps its source as text.

#### Failed equations and warnings

When no engine can typeset an equation, its source stays as text, and the
backend warns once per equation per buffer, naming the buffer and linking to
the log. The failure is recorded, so the equation is not compiled again:
editing it, or changing the preamble or `latex-to-svg-backend-ratex-macros`,
tries again. After a fix outside those (installing a missing TeX package,
upgrading RaTeX), recompile with `C-u M-x latex-to-svg-frontend-refresh`.

To silence these warnings, set `latex-to-svg-frontend-quiet` to `t`. It is
nil by default, and safe as a file- or directory-local variable, so it can be
set for one kind of document in a mode hook or in `.dir-locals.el`.
Configuration problems, such as a missing program, still warn.

#### Choosing the engine for one equation

A LaTeX comment at the top of a display equation chooses its engine, or
leaves it unrendered:

```latex
\[
% engine=skip
x=1
\]

\begin{align}% latex-to-svg: engine=ratex
a &= b
\end{align}
```

| Cookie | Effect |
|--------|--------|
| `engine=latex`, alias `engine=tex` | this equation uses the LaTeX engine |
| `engine=ratex` | this equation uses the RaTeX engine |
| `engine=texres` | this equation uses the texres engine |
| `engine=skip`, alias `engine=none` | no preview: the source stays as text |

- **Where:** a `%` comment before any math, either on the opener line
  (after an environment's arguments, if any) or on its own line right after
  it. A `%` comment further down the body is an ordinary comment.
- **Form:** `%`, then optionally `latex-to-svg:`, then `KEY=VALUE`, with
  blanks allowed around each part.
- **Display math only.** A `%` inside `$…$` comments out the closing `$`, so an
  inline equation cannot carry a cookie.
- **An unknown key or value** (`engine=katex`) warns and leaves the source
  visible. A cookie naming an engine whose program is not found leaves the
  source visible too, and the backend warns, naming the engine and the
  program.
- **A skipped equation still takes its numbers**, as in the exported document,
  so the equations after it keep theirs, and a `\label` in it still resolves.
- **Mixing engines mixes styles.** An equation a cookie sends to the other
  engine is typeset in that engine's style, so a document can show LaTeX's
  Computer Modern next to RaTeX's KaTeX fonts.
- **The cookie is not sent to the backend.** The front-end removes it before
  the equation is compiled and hashed, so a cookie that selects the engine an
  equation would get anyway shares the cached picture of the same equation
  written without it. Hovering still shows the source with its cookie.

### Colors and box

Each preview is tinted and sized like the text at its opening delimiter: an
equation in a heading, a link or a Gnus Subject has the color and the font
size of that text: its letters are as large as the text's. In text drawn in the default foreground it has the
foreground of the `default` face (so it tracks your theme), on a transparent
background. You can override these appearance options — they apply from cache
(no recompiling), and setting one updates the previews on its own:

| Option | Default | Description |
|--------|---------|-------------|
| `latex-to-svg-frontend-foreground-color` | `nil` | Ink color of equations in text drawn in the default foreground; equations in colored text keep the color of the text. `nil` uses the foreground of the `default` face (tracks the theme). |
| `latex-to-svg-frontend-background-color` | `nil` | Box color behind previews; `nil` is transparent. A very light gray reads best (e.g. `gray97` / `#f7f7f7`). |
| `latex-to-svg-frontend-center-display-math` | `nil` | Center display-math previews in the window (inline math is never centered). A display-time indent — redisplay re-centers on resize, split or font change, and setting the option updates the previews on its own. |
| `latex-to-svg-frontend-padding-inline` | `nil` | Padding (pt) between an inline equation and the box edge. A number applies to all four sides; a list of four numbers pads each side separately — `(TOP RIGHT BOTTOM LEFT)`, so `(0 0 0 6)` is a left gutter. `0` crops to the ink; `nil` takes the obsolete `latex-to-svg-frontend-padding`. |
| `latex-to-svg-frontend-padding-display` | `nil` | The same, for display equations. |

### Refreshing on appearance changes

Previews track the buffer colors and font and re-render automatically when they
change. `latex-to-svg-frontend-mode` installs its refresh triggers
**buffer-locally** when enabled (never merely by loading the package):
redisplay (`window-buffer-change-functions`) and zoom (`text-scale-mode-hook`),
so an inactive buffer costs nothing and they are removed when the mode is off.

A theme switch and a *frame* font change are *global* events, with no per-buffer
hook, so the package installs nothing global on your behalf. If you want
previews to follow them instantly, add the provided handler —
`latex-to-svg-frontend-on-appearance-change`, one function for both hooks — the
same way you enable the mode:

```elisp
(add-hook 'enable-theme-functions  #'latex-to-svg-frontend-on-appearance-change)
(add-hook 'after-setting-font-hook #'latex-to-svg-frontend-on-appearance-change)
```

The font hook is what makes `set-frame-font`, `doom/increase-font-size` and
`doom-big-font-mode` rescale previews right away (`text-scale-mode-hook` only
covers *buffer-local* zoom). The handler appearance-checks each buffer
individually, so buffers on an untouched frame cost nothing.

Without it, previews re-tint / rescale on their next redisplay. You can always force a
refresh with `M-x latex-to-svg-frontend-refresh` (current buffer).

### Terminal frames and the Emacs daemon

An equation is compiled only while some frame is graphical, whether or not a
window shows its buffer: a buffer buried in a graphical session has its images
in the cache when it is shown. While every frame is a terminal frame, as in an
Emacs daemon with only terminal clients, nothing is compiled, and the equations
are compiled when a graphical window first shows the buffer.

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

**Which environments.** `latex-to-svg-frontend-detect-environments` is the
on/off switch for the whole family; *which* environments it then covers is
`latex-to-svg-frontend-environments`, a list you can extend (or set to `t` for
any environment). It defaults to the standalone math environments —
`equation`, `align`, `gather`, `multline`, `eqnarray`, `alignat`, `flalign`,
`displaymath`, `math`, `subequations`, and the `breqn` / `empheq` displays —
matched ignoring a trailing `*`, so `equation` covers `equation*` too.

Two things follow from the backend compiling each preview's source **verbatim**
in a `standalone` document:

- Nothing is wrapped in `\[…\]`. An environment renders as whatever it
  typesets on its own — which is why `equation` gives you display math and, if
  you add it, `tikzpicture` gives you a picture.
- An environment that is only valid *inside* a display (`cases`, `matrix`,
  `pmatrix`, `array`, `aligned`, …) cannot be a preview on its own, so it is
  not in the default list. Those still render normally when they appear inside
  a detected span.

An environment opener is also only recognised when nothing but whitespace
precedes it on its line, so prose that mentions `\begin{equation}`
mid-sentence stays prose. The closing `\end{env}` has no such rule.

**Why inline dollar is split out.** A lone `$` is the one delimiter that also
occurs in ordinary prose — prices, shell variables. The scanner guards the
common cases with pandoc's rules: an opening `$` must be followed by a
non-space character, a closing `$` preceded by one and not followed by a
digit, and an escaped `\$` is ignored. As in TeX, the first `$` after an
opening one ends the span. So currency like `$30 and $50` or `$100-$200` is
**not** mistaken for math, and does not pair with the `$` of an equation later
in the paragraph. The price of the digit rule: math directly followed by a
digit, such as `$x$2`, is not detected either. What still slips through is
shell variables such as `$HOME/$USER`, which read as the equation `HOME/`.

Two ways to deal with it:

- **One-off:** escape the dollars — `\$HOME/\$USER` — which the scanner ignores.
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
   backend hands back a cached picture *instantly* if it has one; if not, it
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
| **paste / undo / delete** equations, or stop typing without stepping out | a fraction of a second later, one left-to-right pass over the whole buffer catches what stepping out didn't: it draws the equations that arrived without a picture in the changed range (not the one the cursor is in) and fixes the numbers | one pass over the buffer |
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
- `latex-to-svg-frontend-labels-function` — `(fn)` → hash table from label to
  its printed number, a string; `\ref` / `\eqref` resolve against it instead
  of the buffer's equation labels (LaTeX reads the `.aux` file); optional.
- `latex-to-svg-frontend-find-label-function` — `(fn LABEL)` → non-nil if it
  jumped, called when no equation in the buffer defines LABEL (LaTeX asks
  `xref`); optional.
- `latex-to-svg-frontend-detect-function` — `(fn BEG END)` → list of math
  records, replacing the scanner entirely. Escape hatch; rarely needed.

See `latex-to-svg-for-markdown.el` / `latex-to-svg-for-org.el` /
`latex-to-svg-for-latex.el` / `latex-to-svg-for-gnus.el` as templates.

Pull requests adding adaptors for other major modes are welcome.

## Limitations

- **`\tag`-based references and `subequations` sub-lettering** aren't modelled
  (see [`docs/numbering.md`](docs/numbering.md)).
- **With the `ratex` engine, numbers come from the front-end's row count
  alone.** Where that count is wrong (a `\\` inside `\substack`, for one),
  the preview numbers differently from the exported document; the `latex`
  engine corrects such a count from what LaTeX reports.

## Tests

```sh
emacs -batch -l ert -L . -L ../latex-to-svg-backend \
      -l tests/latex-to-svg-frontend-tests.el -f ert-run-tests-batch-and-exit
```

The backend is stubbed and detection is a regexp scanner, so the suite needs no
TeX toolchain, no graphical display, and (bar one guarded fenced-code test) no
tree-sitter grammar. Point `LATEX_TO_SVG_DIR` at a `latex-to-svg-backend`
checkout if it isn't a sibling directory. The LaTeX adaptor's tests read the
`.aux` files in `tests/fixtures/latex-book/`, which LaTeX wrote, and one of them
needs AUCTeX: point `AUCTEX_DIR` at an AUCTeX checkout or build to run it, or it
skips itself.

## License

GPL-3.0-or-later.
