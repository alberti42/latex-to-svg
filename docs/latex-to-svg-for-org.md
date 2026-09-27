# latex-to-svg-for-org

Org adaptor for `latex-to-svg-frontend`: a thin layer that tells the shared
core which Org regions are code / verbatim / comment (so math inside them is
not previewed) and how to unfold a jump target (`org-fold-show-context`), and
enables the core. All the actual work — detection, overlays, numbering,
references, reveal-on-cursor, refresh — lives in `latex-to-svg-frontend`; see
the [README](../README.md).

## Requirements

Nothing beyond the requirements of the whole stack, in the README's
[Requirements](../README.md#requirements).

## Installation

The adaptor is on MELPA; installing it pulls in the frontend and the backend
(see the README's [Installation](../README.md#installation)):

```elisp
(use-package latex-to-svg-for-org
  :ensure t                  ; with straight: :straight t
  :hook (org-mode . latex-to-svg-for-org-mode))
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
- inline `~code~` / `=verbatim=` spans (via Org's own `org-verbatim-re`), so
  `=\(=` stays literal text.
