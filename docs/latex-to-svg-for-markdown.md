# latex-to-svg-for-markdown

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![MELPA](https://melpa.org/packages/latex-to-svg-for-markdown-badge.svg)](https://melpa.org/#/latex-to-svg-for-markdown)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-for-markdown-badge.svg)](https://stable.melpa.org/#/latex-to-svg-for-markdown)
[![melpazoid](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg)](../LICENSE)

Markdown adaptor for `latex-to-svg-frontend`: a thin layer that tells the
shared core what counts as "code" in a Markdown buffer (so math inside code
is not previewed) and enables the core. All the actual work — detection,
overlays, numbering, references, reveal-on-cursor, refresh — lives in
`latex-to-svg-frontend`; see the [README](../README.md).

![`docs/example.md` in `markdown-mode`: inline math in the prose, `$not math$` left as text in a code span and a fenced block, unnumbered display math, and numbered equations.](../Screenshot-Markdown.png)

## Requirements

The Markdown adaptor works under `markdown-ts-mode` (Emacs 31.1+) **or**
classic `markdown-mode` / `gfm-mode`; the `markdown` tree-sitter grammar is
optional (it makes code-block exclusion exact; without it a regexp fallback
handles fenced and indented blocks). The requirements of the whole stack are
in the README's [Requirements](../README.md#requirements).

## Installation

The adaptor is on MELPA; installing it pulls in the frontend and the backend
(see the README's [Installation](../README.md#installation)):

```elisp
(use-package latex-to-svg-for-markdown
  :ensure t                  ; with straight: :straight t
  :hook (markdown-ts-mode . latex-to-svg-for-markdown-mode))
```

## Usage

Turn on the adaptor mode from your major mode's hook. It also works in classic
`markdown-mode` / `gfm-mode` — hook whichever you use:

```elisp
(add-hook 'markdown-ts-mode-hook #'latex-to-svg-for-markdown-mode)
```

In any other major mode, the mode refuses to turn on.

With the mode on, all math renders when the buffer opens. See
[`example.md`](example.md) for a ready-to-open demo.

## What is not previewed

Math inside code is left as text:

- inline code spans,
- fenced code blocks (either fence character),
- indented code blocks.

Blocks come from the `markdown` tree-sitter grammar when it is installed, else
from an equivalent regexp fallback; inline spans are always regexp. The adaptor
runs the same in `markdown-ts-mode` **or** classic `markdown-mode` /
`gfm-mode` — it uses the `markdown` grammar directly (reusing the buffer's
parser if there is one, else creating its own), so the grammar is an optional
accuracy boost, not a dependency on the major mode.
