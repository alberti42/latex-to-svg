# latex-to-svg-for-org

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![MELPA](https://melpa.org/packages/latex-to-svg-for-org-badge.svg)](https://melpa.org/#/latex-to-svg-for-org)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-for-org-badge.svg)](https://stable.melpa.org/#/latex-to-svg-for-org)
[![melpazoid](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg)](../LICENSE)

Org adaptor for `latex-to-svg-frontend`: a thin layer that tells the shared
core which Org regions are code / verbatim / comment (so math inside them is
not previewed) and how to unfold a jump target (`org-fold-show-context`), and
enables the core. All the actual work — detection, overlays, numbering,
references, reveal-on-cursor, refresh — lives in `latex-to-svg-frontend`; see
the [README](../README.md).

![`docs/example.org` in Org mode: numbered equations, Maxwell's equations numbered per row, click-to-jump `\eqref` references shown as their numbers, and a `#+begin_comment` block left as text.](../Screenshot-Org.png)

## Requirements

Nothing beyond the requirements of the whole stack, in the README's
[Requirements](../README.md#requirements).

## Installation

The adaptor is on MELPA; installing it pulls in the frontend and the backend
(see the README's [Installation](../README.md#installation)):

```elisp
(use-package latex-to-svg-for-org
  :ensure t                  ; with straight: :straight t
  :hook (org-mode . latex-to-svg-for-org-mode)
  :init
  ;; Ignore `#+startup: latexpreview': it would run Org's own preview
  ;; before this mode turns on (see Troubleshooting).
  (with-eval-after-load 'org
    (setq org-startup-options
          (assoc-delete-all "latexpreview" org-startup-options))))
```

## Usage

Turn on the adaptor mode from `org-mode-hook`:

```elisp
(add-hook 'org-mode-hook #'latex-to-svg-for-org-mode)
```

In any other major mode, the mode refuses to turn on.

With the mode on, all math renders when the buffer opens. See
[`example.org`](example.org) for a ready-to-open demo.

`latex-to-svg-for-org-mode` turns off Org's own LaTeX preview while it is on:
`org-latex-preview` (`C-c C-x C-l`, or whatever key runs it) only says so.
Org's preview would draw its own images over these, with no numbering, no
reveal on cursor and a separate cache. To use Org's preview, turn the mode off.

Jumping to an equation from a reference (see the README's
[Numbering and cross-references](../README.md#numbering-and-cross-references))
unfolds the heading that holds it, with `org-fold-show-context`.

## What is not previewed

Math inside these is left as text:

- `#+begin_src` / `example` / `export` / `comment` blocks,
- comment lines,
- table formulas (`#+TBLFM:` lines), which refer to columns as `$1`, `$2`, …,
- fixed-width lines (`: …`, a literal example), such as a shell command
  `: echo ${VARNAME}`,
- inline `~code~` / `=verbatim=` spans (via Org's own `org-verbatim-re`), so
  `=\(=` stays literal text.

## Troubleshooting

### Opening a file with `#+startup: latexpreview` fails

`#+startup: latexpreview` (or `org-startup-with-latex-preview`) makes
`org-mode` run Org's own preview, `org-latex-preview`, while it sets up the
buffer, before `org-mode-hook` turns `latex-to-svg-for-org-mode` on. If Org's
own preview is not properly configured on your system, it fails with an error
such as

```
File "/tmp/orgtexeQT6GZ.dvi" wasn't produced  Please adjust 'dvisvgm' part of 'org-preview-latex-process-alist'.
```

and the error stops `org-mode`'s setup, so the mode is never turned on. When
Org's pipeline works, the overlays produced by Org and by this mode cover the
same math.

The mode renders all math when the buffer opens, so the option `latexpreview`
is not needed. Delete it from the file, or have Org ignore it in every file,
without editing them, with the `:init` lines in [Installation](#installation):

```elisp
(with-eval-after-load 'org
  (setq org-startup-options
        (assoc-delete-all "latexpreview" org-startup-options)))
```

`org-startup-options` lists the words Org accepts after `#+STARTUP:`. The
snippet removes `latexpreview` from that list, and Org ignores a word that is
not in it, so a file that still has `#+startup: latexpreview` no longer runs
Org's preview. `org-startup-options` is a `defconst`: loading Org sets it
again, which would undo a `setq` made before, hence `with-eval-after-load`.
Remove these lines to use Org's own preview again.
