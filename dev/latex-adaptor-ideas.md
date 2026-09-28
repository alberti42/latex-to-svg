# LaTeX adaptor — ideas not built

Designs worked out for `latex-to-svg-for-latex` and set aside, so that the
work is not repeated. None of them is planned.

## Equation numbers that follow `\numberwithin`

Recorded 2026-09-28. Judged not worth the effort for now.

**The limitation.** With `\numberwithin{equation}{section}` the previews
number straight through, (1) … (5), where the document shows (2.1). The same
holds for a chapter in its own file, whose count starts at 1. References are
right, because they come from the `.aux` file.

**The design.** A small LaTeX package of ours, loaded in the user's normal
compile, writes two kinds of lines to the `.aux` file:

```latex
\l2s@within{equation}{section}         % once: equation is reset by section
\l2s@sect{chapters/model.tex}{3}{2}    % the 3rd \section in this file is section 2
```

The package reads the reset rule from LaTeX itself:
`\numberwithin{equation}{section}` puts `equation` on `section`'s reset list
(`\cl@section`). With chapters the chain is chapter → section → equation.

The adaptor's numbering scan then:

1. reads the reset rule from the `.aux` file;
2. finds each unstarred `\section` in the buffer, as it finds equations;
3. at each one, steps the section number and resets the equation count to 0;
4. puts `\setcounter{section}{2}\setcounter{equation}{2}` in front of the
   equation, so that LaTeX, with `\numberwithin` in the project's preamble,
   prints (2.3).

An equation typed in section 2 is counted at once, and the later numbers in
section 2 shift, with no compile. A new `\section` is seen by the scan too.
The compile gives only the starting point: the reset rule, and the section
number where a file begins (a chapter file, or after `\appendix`).

**Work it needs:**

- the scan finds `\chapter`, `\section` and `\subsection`, and skips the
  starred ones and those in comments;
- the incremental renumbering (`--reconcile-from`) notices a `\section` added
  or deleted, and falls back to the full scan;
- the prefix stays byte-identical in a buffer without sectioning, or every
  cached equation of the Org and Markdown adaptors is compiled again;
- TeX must find the package. MELPA installs it inside the Emacs package
  directory, where TeX does not look, so the user sets `TEXINPUTS` or copies
  the file into the project. On CTAN this step disappears;
- the user loads it with `\usepackage`, or AUCTeX adds it to the compile
  command: a `%\`` … `%'` pair in a `TeX-command-list` entry puts TeX code
  before `\input{file}` (`tex.el`), as preview-latex does.

**Rejected on the way:**

- **`preview.sty`** (written in AUCTeX as `latex/preview.dtx`, and in TeX
  Live as the `preview` package). Its counter tracing, `prcounters.def`, works
  only with the `active` option, which replaces the document's output with one
  page per preview and writes the counters to the log. preview-latex runs it
  in a separate pass with `\nofiles`. It cannot be added to the normal compile.
- **An environment variable.** None runs TeX code; `TEXINPUTS` only sets
  where TeX searches for files.
- **One `.aux` line per equation**, with its printed number. The numbers are
  from the last compile: after an edit, the later ones are wrong until the
  next compile.
- **preview-latex's own numbering.** A partial preview numbers right only
  with `preview-preserve-counters` (default nil) and an earlier run over the
  whole buffer or document, whose counters it restores with `\setcounter`.
