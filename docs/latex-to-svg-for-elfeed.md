# latex-to-svg-for-elfeed

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![melpazoid](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg)](../LICENSE)

Elfeed adaptor for `latex-to-svg-frontend`: previews the LaTeX math of the
entry [Elfeed](https://github.com/emacs-elfeed/elfeed) shows in
`elfeed-show-mode`, such as the titles and abstracts of the arXiv feeds. All
the actual work — detection, overlays, reveal-on-cursor, refresh — lives in
`latex-to-svg-frontend`; see the [README](../README.md).

## Requirements

The requirements of the whole stack, in the README's
[Requirements](../README.md#requirements), and Elfeed, from MELPA. The adaptor
does not install Elfeed.

## Installation

The adaptor is not on MELPA yet. Install it from git; it pulls in the frontend
and the backend from MELPA (see the README's
[Installation](../README.md#installation)). With `straight`:

```elisp
(use-package latex-to-svg-for-elfeed
  :straight (latex-to-svg-for-elfeed :type git :host github
                                     :repo "alberti42/latex-to-svg"
                                     :files ("latex-to-svg-for-elfeed.el"))
  :hook (elfeed-show-mode . latex-to-svg-for-elfeed-mode))
```

With `package.el`, the `:preface` below downloads
`latex-to-svg-for-elfeed.el` and installs it with `package-install-file`,
once: only the Elfeed adaptor, with the frontend and the backend from
MELPA. It does not update itself: to upgrade, run `M-x package-delete
RET latex-to-svg-for-elfeed` and restart Emacs.

```elisp
(use-package latex-to-svg-for-elfeed
  :preface
  (unless (package-installed-p 'latex-to-svg-for-elfeed)
    (let ((file (expand-file-name "latex-to-svg-for-elfeed.el"
                                  (make-temp-file "l2s" t))))
      (url-copy-file "https://raw.githubusercontent.com/alberti42/latex-to-svg/main/latex-to-svg-for-elfeed.el"
                     file)
      (package-install-file file)))
  :hook (elfeed-show-mode . latex-to-svg-for-elfeed-mode))
```

Do not install it with `use-package`'s `:vc` (`package-vc`): it puts the
whole repository on `load-path`, so its copies of the frontend and the
other adaptors shadow the ones from MELPA.

## Usage

Turn on the adaptor mode from `elfeed-show-mode-hook`:

```elisp
(add-hook 'elfeed-show-mode-hook #'latex-to-svg-for-elfeed-mode)
```

In any other major mode, the mode refuses to turn on.

Elfeed replaces the text of the entry buffer each time it shows an entry, and
when you revert the buffer (`g`), so the mode draws the previews again from
`elfeed-show-update-hook`. It draws all the math of the entry, the headers
included, such as a `Title:` with `$…$` in it. An equation has the color and
the font height of the text it is in, so an equation in the title has the
title's color and height.

The entry buffer is read-only, so with the default of
`latex-to-svg-frontend-reveal`, `writable`, a preview stays drawn when point
moves onto it. During an Isearch the preview point is on is shown as its LaTeX
source, so a match in it can be seen. Set `latex-to-svg-frontend-reveal` to
`always` to see the source whenever point is on a preview.

## Settings in the entry buffer

Equation numbering (`latex-to-svg-frontend-number-equations`) is off in the
entry buffer: an abstract does not number its equations. To turn it on, set
the variable buffer-locally before the mode, in the same hook.

`$…$` is detected, as in the other adaptors. In a feed, `$` is also currency
("$5 and $10"), which the scanner reads as math. To turn `$…$` off in the
entry buffer:

```elisp
(add-hook 'elfeed-show-mode-hook
          (lambda ()
            (setq-local latex-to-svg-frontend-detect-dollar-inline nil)))
```

## What is not previewed

Nothing is excluded: the adaptor skips no region of the entry, code blocks of
an HTML entry included.

Content that `elfeed-show-fetch-link` inserts after the entry is shown, for a
feed with `:fetch-link`, is drawn by the core's debounced pass on edits, with
a delay, not when it arrives.
