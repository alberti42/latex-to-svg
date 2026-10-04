# latex-to-svg-for-latex

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![MELPA](https://melpa.org/packages/latex-to-svg-for-latex-badge.svg)](https://melpa.org/#/latex-to-svg-for-latex)
[![MELPA Stable](https://stable.melpa.org/packages/latex-to-svg-for-latex-badge.svg)](https://stable.melpa.org/#/latex-to-svg-for-latex)
[![melpazoid](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/latex-to-svg/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/latex-to-svg)](../LICENSE)

LaTeX adaptor for `latex-to-svg-frontend`: a thin layer that tells the shared
core which regions of a LaTeX buffer are comments or verbatim (so math inside
them is not previewed), resolves `\ref` and `\eqref` from the document's
`.aux` file, and enables the core. All the actual work — detection, overlays,
numbering, reveal-on-cursor, refresh — lives in `latex-to-svg-frontend`; see
the [README](../README.md).

![`docs/example.tex` in AUCTeX's `LaTeX-mode`: centered display math, numbered equations, and `\eqref` references showing the numbers read from the `.aux` file.](../Screenshot-LaTeX.png)

## Requirements

Nothing beyond the requirements of the whole stack, in the README's
[Requirements](../README.md#requirements). AUCTeX is optional: with it, the
adaptor finds the `.aux` file through `TeX-master` and `TeX-output-dir`, and
skips the verbatim environments AUCTeX's style files add.

## Installation

The adaptor is on MELPA; installing it pulls in the frontend and the backend
(see the README's [Installation](../README.md#installation)):

```elisp
(use-package latex-to-svg-for-latex
  :ensure t                  ; with straight: :straight t
  :hook ((LaTeX-mode latex-mode) . latex-to-svg-for-latex-mode))
```

## Usage

Turn on the adaptor mode from your major mode's hook, AUCTeX's `LaTeX-mode`
or the built-in `latex-mode`:

```elisp
(add-hook 'LaTeX-mode-hook #'latex-to-svg-for-latex-mode)  ; AUCTeX
(add-hook 'latex-mode-hook #'latex-to-svg-for-latex-mode)  ; built-in tex-mode.el
```

In any other major mode, the mode refuses to turn on.

With the mode on, all math renders when the buffer opens. See
[`example.tex`](example.tex) for a ready-to-open demo; compile it (`latex
example.tex`, twice) so its references find their numbers in the `.aux` file.
Equations that use the project's own macros or packages need the project's
preamble, set in its `.dir-locals.el`: see the README's
[Projects with their own macros](../README.md#projects-with-their-own-macros).

While the mode is on, AUCTeX's preview-latex commands (`preview-at-point`,
`preview-region`, `preview-buffer`, `preview-document`,
`preview-environment`, `preview-section`) only say that they are off:
preview-latex would draw its own images over these. To use preview-latex,
turn the mode off.

In LaTeX buffers the engine is `latex` by default, overriding the global value
of `latex-to-svg-frontend-engine`. RaTeX works too, with
limitations: it ignores every preamble and most packages, so equations that
use the project's macros fail with it (and, with
`latex-to-svg-frontend-fallback` on, are typeset by LaTeX instead). To use
RaTeX anyway, set `latex-to-svg-frontend-engine` buffer-locally, for example
in the project's `.dir-locals.el`; a `% engine=ratex` cookie chooses it for
one equation.

## What is not previewed

Math inside these is left as text:

- comments, from an unescaped `%` to the end of the line;
- `\begin{comment}` … `\end{comment}` and `\iffalse` … `\fi`;
- verbatim environments and macros: `verbatim`, `verbatim*`, `filecontents`,
  `filecontents*`, `\verb|…|` with any delimiter. With AUCTeX loaded, the
  lists are AUCTeX's (`LaTeX-verbatim-environments`,
  `LaTeX-verbatim-macros-with-delims`, `LaTeX-verbatim-macros-with-braces`),
  which include what its style files add, such as `lstlisting` for
  `listings`. To add one, customize AUCTeX's variable;
- the preamble and what follows `\end{document}`, in a file that has
  `\begin{document}`. A file without it, such as a chapter, is all body.

## References

`\ref` and `\eqref` show the number LaTeX printed, read from the document's
`.aux` file: `\ref{sec:model}` shows `2`, `\eqref{eq:energy}` shows `(2.1)`.
This covers labels of sections, figures and tables, and labels in other files
of the document. A label the `.aux` file lacks shows `??` / `(??)`, as LaTeX
does: with no `.aux` file yet, or for a label added since the last compile.

`latex-to-svg-for-latex-aux-file` says where the `.aux` file is:

- **nil** (the default) asks AUCTeX, in `LaTeX-mode`: `TeX-master-output-file`,
  which follows `TeX-master` (a chapter file finds the main file's `.aux`)
  and `TeX-output-dir`. Without AUCTeX, the `.aux` next to the file:
  `paper.tex` → `paper.aux`.
- **A string** is a template: `%b` is the base name of the buffer's file
  (`paper` for `paper.tex`) and `%r` the project root, or the file's directory
  outside a project. A relative result is relative to the file's directory.

| Case | Value |
|---|---|
| AUCTeX knows the main file and the output directory | nil |
| `.aux` files in `._aux/`, set globally | `"._aux/%b.aux"` |
| Main file `main.tex` with a `build/` directory, in the project's `.dir-locals.el` | `"%r/build/main.aux"` |

Emacs applies a string from `.dir-locals.el` without asking.

**After a compile**, the references follow the `.aux` file at the next
reconcile (an edit, or leaving an equation), or at once with
`M-x latex-to-svg-frontend-refresh`. To update them as soon as an AUCTeX
compile finishes, add:

```elisp
(add-hook 'TeX-after-compilation-finished-functions
          #'latex-to-svg-for-latex-update-references)
```

It updates the references in every buffer where the mode is on; a buffer whose
`.aux` file did not change keeps its labels.

**Jumping.** Clicking a reference (`mouse-1` or `mouse-2`), or `C-c C-o` on it,
jumps to its `\label` when the label is in the current buffer. Otherwise, when
the buffer has an xref backend other than etags — such as eglot running
[texlab](https://github.com/latex-lsp/texlab) — it asks `xref-find-definitions`,
which finds the label in any file of the document. The etags backends
(`etags`, and `tex-etags` in Emacs 31, which AUCTeX enables) are not asked:
without a `TAGS` file they prompt for one.

## Compared with AUCTeX's preview-latex

AUCTeX's preview-latex also previews math in place, and since AUCTeX 14.1.1
(January 2026) can make SVG images too, through `dvisvgm`, as an option next to
its default PNG. This adaptor does not depend on AUCTeX: AUCTeX is optional,
and its functions are called only when they are defined. What it offers in
addition:

- **Previews are made and remade without a command.** preview-latex also shows
  an equation's source when the cursor enters its preview, but typesets only on
  command, and an edited equation keeps its old image or an icon until the next
  one. Here, the math renders when the buffer opens, and an edited equation
  renders again as the cursor leaves it.
- **`\ref` and `\eqref` show the numbers from the `.aux` file**, as text over
  the source, and a click jumps to the label, in another file through `xref`.
- **Padding, background and colour are display options**: changing them
  redraws the previews from the cache, with no LaTeX run, as a theme switch and
  a text zoom do.
- **The previews come from the backend's cache**, where each equation is named
  after its content: shared by all buffers and by `agent-shell-math-renderer`,
  kept across sessions, and cleaned of what has not been used for a while.
- **It is a thin layer**, about 500 lines. If you already use the Org or
  Markdown adaptor, it brings the same previews, cache and settings to your
  LaTeX buffers, with nothing else to install.

preview-latex compiles the whole document, so its equation numbers follow
`\numberwithin`, which this adaptor's do not (see
[Limitations](#limitations)).

Both speed up LaTeX with a format file (`.fmt`): the document's preamble is
dumped once with TeX's `\dump`, and every later run loads it instead of
reading the preamble again. The technique is David Carlisle's `mylatex.ltx`,
from 1994, and preview-latex has used it since its release 0.7.4, in 2002.

## Limitations

- **Numbers inside the previews** come from the front-end's count, which
  matches the document when it numbers equations straight through in one file.
  With `\numberwithin{equation}{section}` the previews show (1) … (5) where the
  document shows (2.1). The same holds for a chapter in its own file, whose
  count starts at 1, and for a `\setcounter{equation}` in the text. References
  are right in all three cases, because they come from the `.aux` file.
- **`\cref`, `\autoref` and `\pageref`** stay as source text.
