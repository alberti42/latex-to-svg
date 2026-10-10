# latex-to-svg-for-gnus

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![melpazoid](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg)](../LICENSE)

Gnus adaptor for `latex-to-svg-frontend`: previews the LaTeX math of the
article Gnus shows in `gnus-article-mode`, such as the abstracts of the arXiv
feeds on gwene.org. All the actual work — detection, overlays, reveal-on-cursor,
refresh — lives in `latex-to-svg-frontend`; see the [README](../README.md).

## Requirements

Nothing beyond the requirements of the whole stack, in the README's
[Requirements](../README.md#requirements). Gnus is part of Emacs.

## Installation

The adaptor is not on MELPA yet. Install it from git; it pulls in the frontend
and the backend from MELPA (see the README's
[Installation](../README.md#installation)). With `straight`:

```elisp
(use-package latex-to-svg-for-gnus
  :straight (latex-to-svg-for-gnus :type git :host github
                                   :repo "alberti42/latex-to-svg"
                                   :files ("latex-to-svg-for-gnus.el"))
  :hook (gnus-article-mode . latex-to-svg-for-gnus-mode))
```

With `use-package`'s `:vc` (Emacs 30+):

```elisp
(use-package latex-to-svg-for-gnus
  :vc (:url "https://github.com/alberti42/latex-to-svg"
       :main-file "latex-to-svg-for-gnus.el")
  :hook (gnus-article-mode . latex-to-svg-for-gnus-mode))
```

## Usage

Turn on the adaptor mode from `gnus-article-mode-hook`:

```elisp
(add-hook 'gnus-article-mode-hook #'latex-to-svg-for-gnus-mode)
```

In any other major mode, the mode refuses to turn on.

Gnus reuses one article buffer and replaces its text for each article, so the
mode draws the previews again from `gnus-article-prepare-hook`, every time
Gnus shows an article. It draws all the math of the article, the headers
included, such as a `Subject:` with `$…$` in it. An equation has the color and
the font height of the text it is in, so an equation in the Subject has the
Subject's color and height.

The article buffer is read-only, so with the default of
`latex-to-svg-frontend-reveal`, `writable`, a preview stays drawn when point
moves onto it. During an Isearch the preview point is on is shown as its LaTeX
source, so a match in it can be seen. Set `latex-to-svg-frontend-reveal` to
`always` to see the source whenever point is on a preview.

## Settings in the article buffer

Equation numbering (`latex-to-svg-frontend-number-equations`) is off in the
article buffer: an abstract does not number its equations. To turn it on, set
the variable buffer-locally before the mode, in the same hook.

`$…$` is detected, as in the other adaptors. In mail, `$` is also currency
("$5 and $10"), which the scanner reads as math. To turn `$…$` off in the
article buffer:

```elisp
(add-hook 'gnus-article-mode-hook
          (lambda ()
            (setq-local latex-to-svg-frontend-detect-dollar-inline nil)))
```

## Gnus's emphasis inside math

Gnus reads `_x_`, `/x/` and `*x*` as emphasis (`gnus-emphasis-alist`): it hides
the markers and shows the text in a face. Inside math these characters are
LaTeX. The mode removes Gnus's emphasis from inside math, each time Gnus shows
an article, and keeps it in the prose.

## What is not previewed

Nothing is excluded: mail has no code blocks for the adaptor to skip.
