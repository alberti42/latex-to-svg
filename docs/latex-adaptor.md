# LaTeX adaptor — design and plan

Status: released in 0.18.0 (2026-09-27). This page records what was decided
for `latex-to-svg-for-latex` and in what order it was built. The user
documentation is in [`latex-to-svg-for-latex.md`](latex-to-svg-for-latex.md);
this page keeps the design.

## What it does

`latex-to-svg-for-latex` previews the math of a LaTeX document in its own
buffer, as the Markdown and Org adaptors do for theirs. Two things set it
apart:

- **References come from the `.aux` file.** In a LaTeX document most `\ref`s
  point at sections, figures and tables, which the core's own label table
  (equation labels in the buffer) cannot resolve. The `.aux` file that LaTeX
  writes has the printed number of every `\label`, in every file of the
  document.
- **The project's preamble matters.** Equations use the project's macros and
  packages. That is handled by the backend's preamble options, set in
  `.dir-locals.el` (README, "Projects with their own macros"); the adaptor
  adds nothing for it.

## Decisions

### Modes and setup

- The adaptor turns on in `latex-mode` (built-in `tex-mode.el`) and
  `LaTeX-mode` (AUCTeX), tested with `(derived-mode-p 'latex-mode
  'LaTeX-mode)`, and refuses elsewhere.
- It registers no hook. Its page shows the two lines:

  ```elisp
  (add-hook 'LaTeX-mode-hook #'latex-to-svg-for-latex-mode)  ; AUCTeX
  (add-hook 'latex-mode-hook #'latex-to-svg-for-latex-mode)  ; built-in tex-mode.el
  ```

- Names: `latex-to-svg-for-latex.el`, `latex-to-svg-for-latex-mode`, page
  `docs/latex-to-svg-for-latex.md`.

### What is not previewed

The adaptor's `exclude-function` returns:

- **comments**: from an unescaped `%` to the end of the line;
- **`\begin{comment}` … `\end{comment}`** and **`\iffalse` … `\fi`**;
- **verbatim environments and macros**: from AUCTeX's functions
  `LaTeX-verbatim-environments` and `LaTeX-verbatim-macros-with-delims` when
  AUCTeX is loaded (they include the buffer-local additions of AUCTeX's style
  files, such as `lstlisting` for `listings`), else the same defaults
  (`verbatim`, `verbatim*`, `filecontents`, `filecontents*`; `\verb`,
  `\verb*`). No defcustom of our own: a user who needs more customizes
  AUCTeX's variable;
- **the preamble and what follows `\end{document}`**, in a file that has
  `\begin{document}`. A file without it, such as a chapter, is all body.

### preview-latex

AUCTeX's preview-latex puts its own `display` overlays over the same math.
While the adaptor is on, its keymap remaps the six commands that make them
(`preview-at-point`, `preview-region`, `preview-buffer`, `preview-document`,
`preview-environment`, `preview-section`) to a command that only says so, as
the Org adaptor does for `org-latex-preview`.

### Engine

The adaptor sets `latex-to-svg-frontend-engine` to `latex` buffer-locally.
RaTeX ignores every preamble and most packages, so in a LaTeX project it
fails often and gains little; the option is often set globally for Markdown
and Org. `.dir-locals.el` is applied after the mode hook, so a project can
still choose `ratex`, and a `% engine=ratex` cookie still works.

### References

- **Where the `.aux` file is.** `latex-to-svg-for-latex-aux-file`, a
  buffer-local defcustom, `:safe` `stringp`:
  - nil (the default): ask AUCTeX, `(TeX-master-output-file "aux")`, which
    follows `TeX-master` (a chapter file finds `main.aux`) and
    `TeX-output-dir`. Without AUCTeX, the `.aux` next to the file
    (`paper.tex` → `paper.aux`);
  - a string: a `format-spec` template, `%b` the buffer file's base name,
    `%r` the project root; a relative result is relative to the buffer file's
    directory. Examples: `"._aux/%b.aux"` globally, `"%r/build/main.aux"` in a
    project's `.dir-locals.el`.

  Resolved once when the mode turns on (`TeX-master-file` may search for the
  master file; it is called without ASK, so it never prompts).
- **What is read.** Each `\newlabel{LABEL}{{NUMBER}…}` line: the first braced
  group of the second argument, balanced, with `\relax` and surrounding space
  removed. Both the plain two-field and the hyperref five-field forms have the
  number first. `\@input{chapter.aux}` lines are followed, relative to the
  `.aux` file's directory (`\include`). cleveref's `LABEL@cref` entries are
  skipped. A number that still holds TeX is shown as written.
- **When it is read.** Each buffer keeps, buffer-locally, the `.aux` path, the
  modification time at its last read, and the labels. A reconcile compares the
  file's modification time with the stored one and reads the file again when
  they differ. Several buffers sharing one `.aux` file (chapters of a book)
  each read it: 13 ms for 5,000 labels, once per compile.
- **After a compile.** References follow at the next reconcile, or at once
  with `M-x latex-to-svg-frontend-refresh`. The page shows the line that makes
  it immediate after an AUCTeX compile:

  ```elisp
  (add-hook 'TeX-after-compilation-finished-functions
            #'latex-to-svg-for-latex-update-references)
  ```

  The function ignores its argument (the output file) and runs the check in
  every buffer where the adaptor is on; buffers of other projects find the same
  time and do nothing.
- **A label not in the `.aux` file** (no `.aux` file yet, or a label added
  since the last compile) shows `??` / `(??)`, as LaTeX does.
- **Jumping.** To the `\label` when it is in the current buffer, as the core
  does. Otherwise, when `(xref-find-backend)` is neither `etags` nor
  `tex-etags`, the adaptor calls `xref-find-definitions` at the reference: with
  eglot running texlab, that jumps to the label in any file. The two etags
  backends are excluded because without a `TAGS` file they prompt for one
  (`tex-etags` is Emacs 31's TeX backend, which AUCTeX enables). Otherwise it
  says that the label is not in this buffer. RefTeX has no xref backend and is
  not used.
- **Not supported:** `\cref`, `\autoref`, `\pageref` stay as source text.

### Numbering

The previews keep the front-end's count, which matches the document when it
numbers straight through in one file.

**Limitation, documented on the page:** with `\numberwithin{equation}{section}`
the previews number straight through, (1) … (5), where the document shows
(2.1). References are right, because they come from the `.aux` file. Fixing it
would need the numbering scan to find `\section`s and restart the count there,
a `\setcounter{section}{S}` in the prefix, and the incremental renumbering to
notice a `\section` added or deleted between previews. The same holds for a
chapter in its own file, whose count starts at 1, and a `\setcounter{equation}`
in the text.

## Core changes

The core stays markup-agnostic: both additions are protocol variables, set by
an adaptor, with no knowledge of `.aux` files.

1. **`latex-to-svg-frontend-labels-function`**: `(fn)` → a hash table from
   label to its printed number, a string. When non-nil it replaces the
   numbering scan's label table for references; called once per reconcile.
   This needs:
   - `--reference-display-text` to accept a string number as well as an
     integer;
   - references to be drawn when the function is set, even with
     `latex-to-svg-frontend-number-equations` off (today `--render-element`
     and `--reconcile` need the numbering table);
   - `--reconcile-references` and `--reconcile-from` to take their labels from
     the function.
2. **`latex-to-svg-frontend-find-label-function`**: `(fn LABEL)` → non-nil if
   it jumped. `latex-to-svg-frontend-goto-reference` calls it when
   `--label-position` finds no label in the buffer, with point on the
   reference, instead of signalling "Cannot find an equation labelled".

## Order of work

Each step is a commit, with its tests (backend stubbed, as the suite is now):

1. Core: `labels-function`, string numbers, references without the numbering
   table.
2. Core: `find-label-function` for the jump.
3. Adaptor: the minor mode (mode check, engine, preview-latex remap) and its
   exclusions.
4. Adaptor: where the `.aux` file is (AUCTeX, template).
5. Adaptor: reading the `.aux` file, the modification-time check, the
   `labels-function`, and `latex-to-svg-for-latex-update-references`.
6. Adaptor: the xref jump.
7. Documentation: `docs/latex-to-svg-for-latex.md`, the README's "One adaptor
   per markup" and Installation, the CHANGELOG, and the CI byte-compile list
   (`.github/workflows/ci.yml` names each file).
