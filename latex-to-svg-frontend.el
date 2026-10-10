;;; latex-to-svg-frontend.el --- Preview LaTeX math in markup buffers as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.21.0
;; Package-Requires: ((emacs "29.1") (latex-to-svg-backend "0.14.0"))
;; Keywords: tex, math, images

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; The shared front-end core over the backend, `latex-to-svg-backend'.
;; It detects LaTeX math in a markup buffer, overlays each occurrence with an
;; SVG typeset by the backend, and provides equation numbering, `\\eqref' /
;; `\\ref' resolution, reveal-on-cursor editing, render-on-leave, and theme /
;; zoom refresh.  Per-markup packages (`latex-to-svg-for-markdown',
;; `latex-to-svg-for-org-mode', …) are thin adaptors that plug in only what is
;; markup-specific.
;;
;; Detection is a regexp scanner (`latex-to-svg-frontend--scan') covering:
;;
;;   inline    $ … $     \( … \)
;;   display   $$ … $$    \[ … \]     \begin{env} … \end{env}
;;
;; plus bare `\\eqref' / `\\ref'.  Each delimiter family can be toggled off
;; (`latex-to-svg-frontend-detect-dollar-inline' and friends).  A blank
;; line always bounds a span (LaTeX forbids one inside), which keeps detection
;; from running away on half-typed input.
;;
;; What counts as "code" (regions to skip) and how to unfold a jump target are
;; supplied per-markup through a small buffer-local protocol, all set by an
;; adaptor's minor mode:
;;
;;   `latex-to-svg-frontend-exclude-function'  regions where math is ignored
;;   `latex-to-svg-frontend-reveal-function'   unfold the jump target
;;   `latex-to-svg-frontend-detect-function'   (escape hatch) replace the scanner
;;
;; An adaptor sets these and then toggles `latex-to-svg-frontend-mode' (see its
;; own minor mode, e.g. `latex-to-svg-for-markdown-mode').
;;
;; Because the backend renders its input *verbatim*, the core passes each
;; element's source (delimiters and all).  The backend compiles each unique
;; equation once (content-addressed), color-independent (`--currentcolor',
;; tinted at display) and size-independent (scaled at display), so previews
;; re-tint / re-scale straight from cache — with NO LaTeX recompile — on a
;; theme switch or a text-zoom.
;;
;; Numbered environments (`equation', `align', …) get their real document-wide
;; number baked in as a `\\setcounter' prefix (see docs/numbering.md).  `\\eqref'
;; / `\\ref' resolve against the `\\label' map and show as plain buffer text
;; (e.g. `(3)', in the `latex-to-svg-frontend-reference' face; `(??)' when the
;; target is unknown or was just deleted); they re-resolve on every reconcile,
;; so they never show a stale number, and are click-to-jump to the defining
;; equation.
;;
;; Move point into a preview and it reveals its LaTeX source; leaving re-shows
;; the preview, or re-renders it if the text changed.  Newly typed math renders
;; the moment the cursor leaves it (`--render-on-leave', on `post-command-hook'),
;; never while still inside — so half-typed equations are not compiled.  That
;; same discrete leave event reconciles numbers and references synchronously;
;; the debounced `after-change' pass is only the backstop for edits with no
;; clean leave (delete, paste, undo).  `latex-to-svg-frontend-reveal' sets
;; in which buffers point reveals the source: by default not in a read-only
;; one, except during an Isearch.

;;; Code:

(require 'latex-to-svg-backend)
(require 'seq)
(require 'cl-lib)

(defgroup latex-to-svg-frontend nil
  "Preview LaTeX math in markup buffers as SVG via `latex-to-svg-backend'."
  :group 'text
  :prefix "latex-to-svg-frontend-")

(defcustom latex-to-svg-frontend-engine 'latex
  "Engine that typesets the previews: the symbol `latex', `ratex' or `texres'.

`latex' runs `latex' and `dvisvgm': full LaTeX, with any package the
backend's preamble loads.  `ratex' runs RaTeX's `render-svg': no TeX
installation, for the math KaTeX supports and no packages.  An
equation RaTeX cannot parse is typeset with LaTeX instead, or keeps its
source as text when `latex-to-svg-frontend-fallback' is nil.  `texres'
runs the `pdflatex' of texres, then `pdftocairo': full LaTeX with the
LaTeX engine's preamble, from one program instead of a TeX
installation.  Where the programs are is set in the backend (see
`latex-to-svg-backend-latex-program',
`latex-to-svg-backend-ratex-program' and
`latex-to-svg-backend-texres-program').

Passed to `latex-to-svg-backend' as `:engine'.  Each engine has its
own cache entries, so switching back and forth does not recompile an
equation already compiled by both.  Setting it with `setq',
`setq-local' or Customize updates the previews on its own: the
equations it affects are rendered again.

With `ratex', a numbered environment gets its numbers as a `\\tag{N}' on
each numbered row instead of a `\\setcounter' prefix, and every `\\label'
is removed from what RaTeX receives (see docs/numbering.md).

A display equation can choose its own engine, or stay unrendered, with
a comment at its top: `% engine=latex', `% engine=ratex',
`% engine=texres' or `% engine=skip' (see
`latex-to-svg-frontend--cookie')."
  :type '(choice (const :tag "LaTeX (latex + dvisvgm)" latex)
                 (const :tag "RaTeX (render-svg)" ratex)
                 (const :tag "texres (pdflatex + pdftocairo)" texres))
  :safe (lambda (v) (memq v '(latex ratex texres)))
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-fallback t
  "Whether LaTeX typesets an equation the chosen engine cannot.

When non-nil and an equation's engine is `ratex' (the option
`latex-to-svg-frontend-engine' or its cookie chose it), a formula
that engine rejects, such as one using siunitx's `\\SI',
`\\DeclareMathOperator' or an environment RaTeX lacks (`multline',
`eqnarray', ...), is typeset with LaTeX instead: passed to
`latex-to-svg-backend' as `:fallback'.  The backend records the failure,
so a later request goes straight to the LaTeX picture in the cache.

Two consequences: a fallback equation is typeset in LaTeX's style
\(Computer Modern) next to RaTeX's (KaTeX's fonts), and it takes about
300 ms to compile instead of about 6 ms.  Hovering over an equation
shows which engine typeset it.  The fallback needs `latex' and
`dvisvgm'; without them the backend warns, and you either install them
or set this option to nil.  When nil, an equation the engine rejects
keeps its source as text.  Setting it with `setq', `setq-local' or
Customize updates the previews on its own."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-quiet nil
  "Whether the backend stays silent about an equation it cannot typeset.

When nil (the default), the backend warns once per equation per buffer
about an equation it cannot typeset, naming the buffer and linking to
the log.  When non-nil, it does not; the equation keeps its source as
text.  Passed to `latex-to-svg-backend' as `:quiet'.  Configuration
problems, such as missing programs, still warn.  Set it buffer-locally,
in a mode hook or in `.dir-locals.el', to silence one kind of document."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-number-equations t
  "Whether to compute and bake equation numbers into display-math previews.

When non-nil, numbered LaTeX environments (`equation', `align', …) are
rendered with a `\\setcounter{equation}{N}' prefix so each preview shows
its real document-wide number.  N is derived purely in Elisp by counting
the numbered equations that precede the block (see docs/numbering.md); the
number is part of the backend's content hash, so a block re-renders only
when its number actually changes.

When nil, every element renders verbatim (no numbering)."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-reconcile-idle 0.4
  "Idle seconds before equation numbers are reconciled after an edit.
When numbering is on, editing schedules a debounced pass that re-renders
any downstream preview whose number changed (see
`latex-to-svg-frontend--reconcile').  nil disables the automatic pass
\(numbers then refresh only on an explicit render)."
  :type '(choice (const :tag "Disabled" nil) number)
  :safe (lambda (v) (or (null v) (numberp v)))
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-incremental-reconcile t
  "When non-nil, renumber incrementally on a cursor-leave render.
Leaving a just-typed or edited equation renumbers only from that equation
downward, seeding the counter from the nearest preceding overlay and
stopping as soon as numbers realign -- no whole-buffer scan (see
`latex-to-svg-frontend--reconcile-from').  The equation's own number is
likewise computed from that preceding overlay rather than by a full scan.
Falls back to a full `latex-to-svg-frontend--reconcile' on any structural
surprise, and the debounced backstop / explicit commands always use the
full pass.  Set to nil to force the full scan everywhere."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

;; Before the defcustoms on purpose, like the padding alias below:
;; `defvaralias' discards a value the obsolete name already holds.
(define-obsolete-variable-alias 'latex-to-svg-frontend-inline-rescale
  'latex-to-svg-frontend-rescale-inline "0.18.0")
(define-obsolete-variable-alias 'latex-to-svg-frontend-display-rescale
  'latex-to-svg-frontend-rescale-display "0.18.0")

(defcustom latex-to-svg-frontend-rescale-inline 1.0
  "Size multiplier for inline math previews (`$…$', `\\(…\\)').
Applied on top of the backend's global `latex-to-svg-backend-font-scale' via
`latex-to-svg-backend's `:rescale-by'.  Re-scales from cache (no
recompile).  Setting it with `setq', `setq-local' or Customize updates
the previews on its own."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-rescale-display 1.0
  "Size multiplier for display math previews (`\\=\\[…\\=\\]', `$$…$$', environments).
Applied on top of the backend's global `latex-to-svg-backend-font-scale' via
`latex-to-svg-backend's `:rescale-by' — e.g. set to 1.1 for display equations a
touch larger than inline.  Re-scales from cache (no recompile).  Setting
it with `setq', `setq-local' or Customize updates the previews on its
own."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-foreground-color nil
  "Color of equations in text drawn in the default foreground, or nil.

Each equation is tinted with the foreground of the text at its opening
delimiter, so an equation in a heading, a link or a Gnus Subject has
the color of that text.  When that text has no foreground of its own,
or the foreground of the `default' face, the equation is tinted with
this color instead, if it is non-nil: a `#rrggbb' string or any name
`color-values' understands (e.g. \"black\", \"#1a1a1a\").  Nil
\(the default) leaves those equations in the foreground of the
`default' face, which tracks the theme.  Colors are read on the frame
that shows the buffer, and a name that frame cannot resolve is reported
with a warning and treated as nil.  Passed to `latex-to-svg-backend' as
`:color', as a `#rrggbb' string; re-tints from cache (no recompile).
Setting it with `setq', `setq-local' or Customize updates the previews
on its own."
  :type '(choice (const :tag "Follow the default foreground" nil)
                 (color :tag "Color for default-colored text"))
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-background-color nil
  "Box color painted behind equation previews, or nil for transparent.

When nil (the default) previews are transparent and blend into the
buffer.  Set to a color — a `#rrggbb' string or any name
`color-values' understands — to paint that color behind every
preview.  A very light gray reads best (e.g. \"gray97\" / \"#f7f7f7\");
keep it subtle so it doesn't fight the buffer background.  The color is
read on the frame that shows the buffer, and a name that frame cannot
resolve is reported with a warning and treated as nil.  Passed to
`latex-to-svg-backend' as `:background', as a `#rrggbb' string;
re-boxes from cache (no recompile).  Setting it with `setq',
`setq-local' or Customize updates the previews on its own."
  :type '(choice (const :tag "Transparent" nil)
                 (color :tag "Box color"))
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'latex-to-svg-frontend)

;; Before the defcustom on purpose: `defvaralias' discards a value the
;; obsolete name already holds, so a config that sets the old name before
;; this file loads would silently lose it if the alias came afterwards.
(define-obsolete-variable-alias 'latex-to-svg-frontend-background-padding
  'latex-to-svg-frontend-padding "0.16.0")

(defconst latex-to-svg-frontend--padding-type
  '(choice (const :tag "None" nil)
           (number :tag "All four sides (pt)")
           (list :tag "Per side (pt)"
                 (number :tag "Top   ")
                 (number :tag "Right ")
                 (number :tag "Bottom")
                 (number :tag "Left  ")))
  "Customize type of the padding options.")

(defun latex-to-svg-frontend--padding-p (value)
  "Non-nil when VALUE is a padding the backend accepts: nil, or 1-4 numbers.
The `:safe' predicate of the padding options.  A file-local value is
hand-written Lisp, so it accepts every shape the backend does, not just
the two Customize offers."
  (or (null value) (numberp value)
      (and (consp value) (<= 1 (length value) 4)
           (seq-every-p #'numberp value))))

(defcustom latex-to-svg-frontend-padding nil
  "Padding (in pt) added around every equation preview.
Obsolete: set `latex-to-svg-frontend-padding-inline' and
`latex-to-svg-frontend-padding-display' instead.  A kind whose own
option is nil takes this value, so setting it still pads both kinds.
The values are the same as theirs."
  :type latex-to-svg-frontend--padding-type
  :safe #'latex-to-svg-frontend--padding-p
  :group 'latex-to-svg-frontend)
(make-obsolete-variable
 'latex-to-svg-frontend-padding
 "set `latex-to-svg-frontend-padding-inline' and \
`latex-to-svg-frontend-padding-display'."
 "0.18.0")

(defcustom latex-to-svg-frontend-padding-inline nil
  "Padding (in pt) added around inline math previews (`$…$', `\\(…\\)').

Grows the box beyond the equation ink, and scales with the equation.
Either a number of pt (e.g. 3) applied to all four sides, or a list of
four numbers (TOP RIGHT BOTTOM LEFT) to pad each side separately -- so
a left gutter and nothing else is (0 0 0 6).  0 crops the box to the
ink.  nil takes the value of the obsolete `latex-to-svg-frontend-padding',
which crops too unless it is set.  Set from Lisp, the shorter CSS forms
the backend accepts work too (one, two or three numbers: see
`latex-to-svg-backend'), but Customize offers only the number and the
four-side list.

This mainly matters with `latex-to-svg-frontend-background-color' set,
since padding is what separates the ink from the box edge.  Without a
box color the padding is transparent, so a symmetric value is invisible
but an asymmetric one still shifts the equation within its own image
\(a left-only pad indents it).

Passed to `latex-to-svg-backend' as `:padding'; applies from cache (no
recompile).  Setting it with `setq', `setq-local' or Customize updates
the previews on its own.  See `latex-to-svg-frontend-padding-display'
for display math."
  :type latex-to-svg-frontend--padding-type
  :safe #'latex-to-svg-frontend--padding-p
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-padding-display nil
  "Padding (in pt) added around display math previews.
Display math is `\\=\\[…\\=\\]', `$$…$$' and environments.  The values
are those of `latex-to-svg-frontend-padding-inline', which pads inline
math: a number for all four sides, a list (TOP RIGHT BOTTOM LEFT), 0
to crop to the ink, or nil for the value of the obsolete
`latex-to-svg-frontend-padding'.  Applies from cache (no recompile).
Setting it with `setq', `setq-local' or Customize updates the previews
on its own."
  :type latex-to-svg-frontend--padding-type
  :safe #'latex-to-svg-frontend--padding-p
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-center-display-math nil
  "Whether to center display-math previews in the window.

Display math is centered the way a LaTeX document centers it, rather
than starting at the left margin.  Inline math is never centered: it
belongs in the run of text.

The indent is applied at display time, not baked into the image: the
preview keeps its own size and any
`latex-to-svg-frontend-padding-display' box, and a space before it
stretches to put its center on the window's center.  The stretch is
computed by redisplay, so it follows a window resize, a split, a font
change or `display-line-numbers-mode' on its own -- no refresh needed
for those.  Setting the option itself with
`setq', `setq-local' or Customize updates the previews on its own.

An equation wider than the window, or one that does not start its own
line, simply stays where it is: the space cannot pull it left."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-dollar-inline t
  "Whether to detect inline TeX dollar math `$…$'.
`$' is the least reliable delimiter, since it also occurs in prose (prices,
shell variables).  The scanner applies pandoc's guards — an opening `$'
must be followed by a non-space, a closing `$' preceded by a non-space
and not followed by a digit, and an escaped `\$' is ignored — and, as in
TeX, the first `$' after an opening one ends the span.  So currency like
\"$30 and $50\" or \"$100-$200\" is not mistaken for math, and does not
pair with the `$' of an equation later in the paragraph.  Math directly
followed by a digit, such as `$x$2', is not detected either.  What still
slips through is shell variables such as \"$HOME/$USER\"; escape them as
\"\$HOME/\$USER\" for a one-off, or turn this off (leaving the other three
families on) and use `\(…\)' in buffers where `$' is mostly prose."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-dollar-display t
  "Whether to detect display TeX dollar math `$$…$$'.
Safe to keep on even when `latex-to-svg-frontend-detect-dollar-inline' is
off: a doubled `$$' is unlikely to occur by accident in prose."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-bracket-inline t
  "Whether to detect inline LaTeX bracket math `\\(…\\)'."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-bracket-display t
  "Whether to detect display LaTeX bracket math `\\=\\[…\\=\\]'."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-environments t
  "Whether to detect LaTeX environments `\\begin{env}…\\end{env}'."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-environments
  '("equation" "math" "displaymath" "multline" "dmath" "empheq"
    "eqnarray" "align" "alignat" "flalign" "gather"
    "xalignat" "xxalignat" "subequations" "dseries" "dgroup" "darray")
  "LaTeX environments to render, or t for any environment.
A trailing `*' is ignored when matching, so \"equation\" also covers
`equation*'.  Add a name to render other standalone environments — e.g.
`tikzpicture', `tabular', or a package's own display — and remove one to
leave it as literal source.

Only environments that are valid on their own are useful here: the backend
compiles each preview's source verbatim in a `standalone' document, so an
environment that must sit inside a display (`cases', `matrix', `pmatrix',
`array', …) cannot be a top-level preview.  Those still render fine
*inside* a detected span, which is why they are absent from the default.

Whether the environment then typesets as math is up to the environment
itself; nothing here wraps the source in `\\=\\[…\\=\\]'.  The whole family can be
switched off with `latex-to-svg-frontend-detect-environments'.

An environment opener is also only recognised when nothing but whitespace
precedes it on its line, so a `\\begin' mid-sentence stays prose."
  :type '(choice (const :tag "Any environment" t)
                 (repeat :tag "Environment names" string))
  :safe (lambda (v) (or (eq v t)
                        (and (listp v) (seq-every-p #'stringp v))))
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-references t
  "Whether to detect `\\eqref' / `\\ref' and show them as resolved numbers.
Only meaningful with `latex-to-svg-frontend-number-equations' on, since the
number comes from the document's `\\label' map.  When off, `\\eqref' / `\\ref'
are left as literal source."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-return-follows-reference nil
  "Non-nil means RET on an `\\eqref' / `\\ref' preview follows it.
Off by default, mirroring `org-return-follows-link': the buffer is
editable, so RET should insert a newline -- including with point at the
very start of a reference, where the preview's keymap is already active.
\\<latex-to-svg-frontend--reference-keymap>\\[latex-to-svg-frontend-goto-reference] follows a reference regardless."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-reveal 'writable
  "When the preview point is on is shown as its LaTeX source.
`always' means in every buffer, `writable' in a buffer that is not
read-only, and nil never.  During an Isearch the preview point is on is
shown as its LaTeX source whatever the value, so a match in it can be
seen.  Editing a preview shows its source whatever the value."
  :type '(choice (const :tag "In every buffer" always)
                 (const :tag "In a buffer that is not read-only" writable)
                 (const :tag "Never" nil))
  :safe (lambda (value) (memq value '(always writable nil)))
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-suppress-emphasis t
  "Whether to strip markup emphasis decoration from math source text.
Markup font-lock (Org's `+…+' / `_…_' / `/…/', Markdown's `*…*', ...) has no
LaTeX awareness and paints `:strike-through' / `:underline' onto math that
merely resembles emphasis (`(+)', `_i', `/x/', ...).  A live preview overlay
already masks this, but freshly typed or currently-edited math has none.  When
non-nil, a font-lock pass neutralizes that decoration over every detected math
span (see `latex-to-svg-frontend--suppress-emphasis')."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-frontend)

;;;; Per-markup protocol (buffer-local; set by an adaptor's minor mode)

(defvar-local latex-to-svg-frontend-exclude-function nil
  "Function (BEG END) -> list of (B . E) regions where math must be ignored.
A mode adaptor sets this to the buffer's code / verbatim regions so the
scanner skips math inside them.  nil means no exclusions.")

(defvar-local latex-to-svg-frontend-reveal-function nil
  "Function of no args, called after a jump to unfold the target.
E.g. Org sets it to `org-fold-show-context'.  nil means no unfolding.")

(defvar-local latex-to-svg-frontend-labels-function nil
  "Function of no args -> hash table from label to its printed number.
The number is a string, such as \"2.1\".  When non-nil, `\\eqref' /
`\\ref' resolve against this table instead of the equation labels the
numbering scan finds in the buffer, and are drawn even with
`latex-to-svg-frontend-number-equations' off.  A label missing from it
shows \"(??)\" / \"??\".  Called once per reconcile, so it should return
a table it keeps rather than build one each time.  E.g. the LaTeX
adaptor reads the document's `.aux' file.  nil means the buffer's own
equation labels.")

(defvar-local latex-to-svg-frontend-find-label-function nil
  "Function (LABEL) -> non-nil if it jumped to where LABEL is defined.
`latex-to-svg-frontend-goto-reference' calls it, with point on the
reference, when LABEL is not defined by an equation in the buffer.
E.g. the LaTeX adaptor asks `xref' for a label in another file.  nil
means the jump reports that the label cannot be found.")

(defvar-local latex-to-svg-frontend-detect-function nil
  "Escape hatch: function (BEG END) -> list of math records.
When non-nil it replaces the built-in scanner entirely (see
`latex-to-svg-frontend--detect'); adaptors normally leave this nil.")

(defconst latex-to-svg-frontend--metadata-prefix "L2S="
  "Marker prefix for the `\\typeout' number probe (a distinctive `key='.
Installed as `latex-to-svg-backend-metadata-prefix' so the backend captures the
block's final `equation' counter into its `.eld' sidecar.")

(defface latex-to-svg-frontend-reference '((t :inherit link))
  "Face for inline `\\eqref' / `\\ref' number previews.
These are shown as ordinary buffer text (e.g. `(3)') in this face, not
typeset by LaTeX, so they match the surrounding prose font.  Set it to
`default' for a plain, unlinked look."
  :group 'latex-to-svg-frontend)

(defconst latex-to-svg-frontend--neutralize-face
  '(:strike-through nil :underline nil :overline nil
    :weight normal :slant normal :box nil)
  "Face that neutralizes spurious markup emphasis over math.
Markup font-lock (e.g. Org's emphasis fontifier) has no LaTeX awareness
and fontifies math that merely resembles emphasis: `(+)' / `_i' as
strike-through / underline, `*x*' as bold, `/x/' as italic.  Inside an
equation `*', `/', `_', `+' are LaTeX syntax, never prose emphasis, so all
of it is spurious.  This spec explicitly turns those attributes off; every
other attribute (colours, etc.) falls through untouched.

Used two ways, both scoped to detected math only: as a preview overlay's
own `face' (with a `priority'), so a `display' image or string is not
decorated by the buffer text beneath it; and prepended to the `face' text
property of raw math source by `latex-to-svg-frontend--suppress-emphasis'.")

;;;; Math element model
;;
;; The scanner produces our own lightweight records (markup parse trees don't
;; expose math generically).  A record has a TYPE (`fragment' or
;; `environment'), its buffer BEGIN / END, and its verbatim source VALUE
;; (delimiters / `\begin…\end' and all — exactly what the backend renders).

(cl-defstruct (latex-to-svg-frontend--math
               (:constructor latex-to-svg-frontend--math-make)
               (:copier nil))
  "A detected LaTeX math span."
  type begin end value)

(defconst latex-to-svg-frontend--element-types '(fragment environment)
  "Math element types rendered as equations.")

(defun latex-to-svg-frontend--display-p (source)
  "Non-nil when math SOURCE is display (environment, `\\=\\[…\\=\\]', or `$$…$$').
Inline `$…$' / `\\(…\\)' return nil."
  (let ((s (string-trim-left source)))
    (or (string-prefix-p "\\begin" s)
        (string-prefix-p "\\[" s)
        (string-prefix-p "$$" s))))

(defun latex-to-svg-frontend--rescale-for (display-p)
  "Return the `:rescale-by' factor for a DISPLAY-P (else inline) preview."
  (if display-p
      latex-to-svg-frontend-rescale-display
    latex-to-svg-frontend-rescale-inline))

(defun latex-to-svg-frontend--padding-for (display-p)
  "Return the `:padding' for a DISPLAY-P (else inline) preview.
That is `latex-to-svg-frontend-padding-display' or
`latex-to-svg-frontend-padding-inline', or, when it is nil, the
obsolete `latex-to-svg-frontend-padding'."
  (or (if display-p
          latex-to-svg-frontend-padding-display
        latex-to-svg-frontend-padding-inline)
      (with-suppressed-warnings ((obsolete latex-to-svg-frontend-padding))
        latex-to-svg-frontend-padding)))

;; Defined only in an Emacs built with a window system; it is called only
;; while a graphical window shows the buffer.
(declare-function font-info "font.c" (name &optional frame))

(defvar-local latex-to-svg-frontend--font-warned nil
  "Non-nil once an unmeasurable buffer font has been reported in this buffer.")

(defun latex-to-svg-frontend--x-height-ratio (name frame)
  "Return the x-height of the font NAME on FRAME as a fraction of its size.
That is the ascent of its glyph for `x' divided by its pixel size,
read with the font opened at 1000 pixels: `font-get-glyphs' gives
whole pixels, which at a text size of 18 pixels is off by up to 5%.
Emacs keeps a font it has opened, so a repeat costs about a
microsecond.  Nil when FRAME finds no font NAME, or the font has no
glyph for `x', as a symbol font has none."
  (when-let* ((entity (find-font (font-spec :name name) frame))
              (font (open-font entity 1000 frame))
              (glyph (aref (font-get-glyphs font 0 1 "x") 0)))
    (/ (aref glyph 7) 1000.0)))

(defun latex-to-svg-frontend--x-height (&optional buffer)
  "Return the x-height of BUFFER's default font in a graphical frame, or nil.
That is the height of the lowercase `x' of the font of the `default'
face, in pixels: its pixel size, slot 2 of `font-info' of `face-font',
times its ratio (`latex-to-svg-frontend--x-height-ratio').
`face-font' follows the buffer's face remapping, so `text-scale-mode'
applies.

Measured against the frame that actually displays BUFFER, so the size
is right even when the selected frame is a TTY/daemon frame (an async
compile callback firing while a terminal frame is current).  Uses
`with-selected-frame' (a temporary, non-raising, non-focus-stealing
selection), so it never makes a parked child frame appear.  Returns
nil when BUFFER is shown in no graphical window, in which case the
backend compiles the equation but sizes nothing, and the refresh hook
draws it once a graphical window shows BUFFER.

A font the frame cannot open, or one with no glyph for `x', yields nil
as well, but is reported once per buffer rather than passed over."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((window (latex-to-svg-frontend--display-window buffer)))
      (with-selected-frame (window-frame window)
        (with-current-buffer buffer
          (let* ((font (face-font 'default))
                 (info (and font (font-info font)))
                 (ratio (and info (latex-to-svg-frontend--x-height-ratio
                                   font (selected-frame)))))
            (if ratio
                (* (aref info 2) ratio)
              (unless latex-to-svg-frontend--font-warned
                (setq latex-to-svg-frontend--font-warned t)
                (display-warning
                 'latex-to-svg-frontend
                 (format "Cannot measure the x-height of the buffer font: %S"
                         font)
                 :warning))
              nil)))))))

(defun latex-to-svg-frontend--display-window (buffer)
  "Return a window showing BUFFER on a graphical frame, or nil.
Previews are measured and tinted against its frame (see
`latex-to-svg-frontend--x-height')."
  (when-let* ((win (get-buffer-window buffer t))
              ((display-graphic-p (window-frame win))))
    win))

(defun latex-to-svg-frontend--graphical-p ()
  "Return non-nil when some live frame is graphical.
An image can then be displayed in this session, whether or not a window
shows the buffer.  This decides whether to render at all: while every
frame is a terminal frame, nothing is sent to the backend.  The frame
an equation is measured and tinted against is `--display-frame'.  A
frame found here is neither measured nor selected, so a parked child
frame, which exists only in a graphical session, gives the right answer
too."
  (seq-some #'display-graphic-p (frame-list)))

(defvar-local latex-to-svg-frontend--undrawn nil
  "Non-nil when math may lack a preview until a graphical window shows it.
`--place' sets it when it sends no request (see `--graphical-p') or sends
one with no display frame, for which the backend compiles and returns
no image.  `--refresh-if-changed' renders that math once a graphical
window shows the buffer.")

(defun latex-to-svg-frontend--display-frame (buffer)
  "Return the graphical frame of a window showing BUFFER, or nil.
See `latex-to-svg-frontend--display-window'."
  (when-let* ((win (latex-to-svg-frontend--display-window buffer)))
    (window-frame win)))

(defun latex-to-svg-frontend--x-height-at (pos &optional buffer)
  "Return the x-height of the font of the text at POS in BUFFER, or nil.
That is the height of the lowercase `x' of the font Emacs uses at POS,
the opening delimiter of an equation, in a window showing BUFFER (see
`latex-to-svg-frontend--display-window'), in pixels: its pixel size,
slot 2 of `query-font', times its ratio
\(`latex-to-svg-frontend--x-height-ratio').  The faces at POS and their
`:height' apply, and so does `text-scale-mode'.  When no font is found
at POS, or it has no glyph for `x', it is
`latex-to-svg-frontend--x-height', which is nil when BUFFER is shown
in no graphical window."
  (let ((buffer (or buffer (current-buffer))))
    (or (when-let* ((win (latex-to-svg-frontend--display-window buffer)))
          (with-selected-frame (window-frame win)
            (with-current-buffer buffer
              (when-let* ((font (ignore-errors (font-at pos win)))
                          (info (query-font font))
                          (ratio (latex-to-svg-frontend--x-height-ratio
                                  (aref info 0) (window-frame win))))
                (* (aref info 2) ratio)))))
        (latex-to-svg-frontend--x-height buffer))))

(defun latex-to-svg-frontend--text-foreground (pos &optional frame)
  "Return the foreground the faces of the text at POS give it, or nil.
Follows `foreground-color-at-point' (see `faces--attribute-at-point'),
with three differences.  It reads text properties only, not overlays,
so the preview overlay of this package at POS does not hide the face
of the text.  It reads the faces on FRAME (nil: the selected frame).
When no face at POS specifies a foreground, it returns nil, not the
foreground of the `default' face.

The faces are the `font-lock-face' property when `font-lock-mode' is
on and the text has one, else the `face' property: a face, a list of
faces (the first that specifies a foreground wins), or an anonymous
face such as (:foreground \"gold\") or (foreground-color . \"gold\")."
  (let ((faces (or (and font-lock-mode
                        (get-text-property pos 'font-lock-face))
                   (get-text-property pos 'face)))
        (found nil))
    (dolist (face (if (face-list-p faces) faces (list faces)))
      (cond (found)
            ((and face (symbolp face))
             (let ((value (face-attribute-specified-or
                           (face-attribute face :foreground frame t)
                           nil)))
               (unless (member value '(nil "unspecified-fg" "unspecified-bg"))
                 (setq found value))))
            ((consp face)
             (setq found (cond ((memq 'foreground-color face)
                                (cdr (memq 'foreground-color face)))
                               ((memq :foreground face)
                                (cadr (memq :foreground face))))))))
    found))

(defun latex-to-svg-frontend--default-foreground-p (color &optional frame)
  "Return non-nil if COLOR is the foreground of the `default' face on FRAME.
Colors compare by value, so \"white\" and \"#ffffff\" are the same.  A
color without values, such as \"unspecified-fg\" on a terminal, is
never the default."
  (let ((rgb (color-values color frame)))
    (and rgb
         (equal rgb (color-values (face-foreground 'default frame t) frame)))))

(defun latex-to-svg-frontend--hex-color (color frame)
  "Return COLOR as a `#rrggbb' string, resolved on FRAME, or nil.
A `#rrggbb' string is returned as it is.  Other colors are read with
`color-values', whose 16-bit components are rounded to 8 bits.  Nil
when COLOR is nil or FRAME cannot resolve it."
  (cond ((null color) nil)
        ((string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color) color)
        ((when-let* ((values (color-values color frame)))
           (apply #'format "#%02x%02x%02x"
                  (mapcar (lambda (v) (round (* v 255) 65535)) values))))))

(defvar latex-to-svg-frontend--warned-colors nil
  "The (OPTION . VALUE) pairs reported as colors no frame resolved.")

(defun latex-to-svg-frontend--option-color (option frame)
  "Return the color in OPTION as a `#rrggbb' string resolved on FRAME, or nil.
Nil when OPTION is nil.  A value FRAME cannot resolve is nil too, and
is reported once with `display-warning'."
  (when-let* ((color (symbol-value option)))
    (or (latex-to-svg-frontend--hex-color color frame)
        (let ((pair (cons option color)))
          (unless (member pair latex-to-svg-frontend--warned-colors)
            (push pair latex-to-svg-frontend--warned-colors)
            (display-warning
             'latex-to-svg-frontend
             (format "Cannot resolve `%s' (%S) as a color; ignoring it"
                     option color)
             :warning))
          nil))))

(defun latex-to-svg-frontend--foreground-for (pos frame)
  "Return the `#rrggbb' color to tint the equation that opens at POS with.
That is the foreground of the text at POS, the opening delimiter of the
equation (see `latex-to-svg-frontend--text-foreground'), read on FRAME.
When the text has no foreground of its own, or the foreground of the
`default' face, it is `latex-to-svg-frontend-foreground-color', and
when that is nil, the foreground of the `default' face on FRAME.  Each
is resolved on FRAME (see `latex-to-svg-frontend--hex-color').  Nil
only when FRAME is nil: the buffer is shown in no graphical window."
  (when frame
    (let ((text (latex-to-svg-frontend--text-foreground pos frame)))
      (or (and text
               (not (latex-to-svg-frontend--default-foreground-p text frame))
               (latex-to-svg-frontend--hex-color text frame))
          (latex-to-svg-frontend--option-color
           'latex-to-svg-frontend-foreground-color frame)
          (latex-to-svg-frontend--hex-color
           (face-foreground 'default frame t) frame)))))

(defun latex-to-svg-frontend--background-for (frame)
  "Return the `#rrggbb' color of the box behind each preview, or nil.
That is `latex-to-svg-frontend-background-color', resolved on FRAME.
Nil, a transparent box, when the option is nil or FRAME is nil."
  (and frame
       (latex-to-svg-frontend--option-color
        'latex-to-svg-frontend-background-color frame)))

(defun latex-to-svg-frontend--appearance (&optional buffer)
  "Return the appearance signature of BUFFER's previews (default current).
A list (FOREGROUND BACKGROUND X-HEIGHT): the foreground and the
background of the `default' face on the frame that shows BUFFER (see
`latex-to-svg-frontend--display-frame'), and
`latex-to-svg-frontend--x-height'.  All three are nil when BUFFER
is shown in no graphical window."
  (let* ((buffer (or buffer (current-buffer)))
         (frame (latex-to-svg-frontend--display-frame buffer)))
    (list (and frame (face-foreground 'default frame t))
          (and frame (face-background 'default frame t))
          (latex-to-svg-frontend--x-height buffer))))

(defconst latex-to-svg-frontend--numbered-environments-single
  '("equation" "math" "displaymath" "multline" "dmath" "empheq")
  "LaTeX environments that produce a single numbered equation.
`multline' lives here (not with the multi-row environments): it typesets
one number for the whole line-broken equation, so its `\\\\' are line
breaks, not equation separators.")

(defconst latex-to-svg-frontend--numbered-environments-multi
  '("eqnarray" "align" "alignat" "flalign" "gather"
    "xalignat" "xxalignat" "subequations" "dseries" "dgroup" "darray")
  "LaTeX environments that produce one numbered equation per row.
`subequations' is best-effort (its inner environments are counted, but
the `N.a'/`N.b' sub-lettering is not modelled).")

(defconst latex-to-svg-frontend--numbered-environments-all
  (append latex-to-svg-frontend--numbered-environments-single
          latex-to-svg-frontend--numbered-environments-multi)
  "All LaTeX environments that produce numbered equations.")

;; Forward declaration: the minor-mode variable is defined by the
;; `define-minor-mode' at the end of the file but referenced by the refresh
;; helpers above it.
(defvar latex-to-svg-frontend-mode)

;; Forward declaration: the reference-overlay keymap is defined with the
;; interactive commands near the end of the file, but `--set-reference-overlay'
;; (above it) installs it on `\eqref' / `\ref' previews.
(defvar latex-to-svg-frontend--reference-keymap)

(defvar-local latex-to-svg-frontend--rendered-appearance nil
  "Appearance signature this buffer's previews were last rendered for.
A value of `latex-to-svg-frontend--appearance', compared against the current one
so a lazy refresh can detect a theme or font-size change and re-tint /
re-scale from cache.")

;;;; Element detection (regexp scanner)

(defconst latex-to-svg-frontend--opener-regexp
  (concat "\\$\\$"                                  ; $$   display open
          "\\|" "\\$"                               ; $    inline open
          "\\|" "\\\\\\["                           ; \[   display open
          "\\|" "\\\\("                             ; \(   inline open
          "\\|" "\\\\begin{\\([A-Za-z0-9*]+\\)}"    ; \begin{ENV}
          "\\|" "\\\\eqref{[^}]*}"                  ; \eqref{…}
          "\\|" "\\\\ref{[^}]*}")                   ; \ref{…}
  "Regexp matching the start of any recognised math span.
Group 1, when set, is the environment name of a `\\begin{ENV}' opener.
Alternatives are ordered so `$$' wins over `$' and `\\eqref' over `\\ref'.")

(defun latex-to-svg-frontend--escaped-p (pos)
  "Non-nil when the character at POS is preceded by an odd number of backslashes."
  (let ((n 0) (p pos))
    (while (and (> p (point-min)) (eq (char-before p) ?\\))
      (setq n (1+ n) p (1- p)))
    (cl-oddp n)))

(defun latex-to-svg-frontend--exclusions (beg end)
  "Return code / verbatim regions within BEG..END to skip.
Delegates to the buffer-local `latex-to-svg-frontend-exclude-function'
\(installed by a mode adaptor); nil when none is set."
  (and latex-to-svg-frontend-exclude-function
       (funcall latex-to-svg-frontend-exclude-function beg end)))

(defun latex-to-svg-frontend--in-code-p (pos regions)
  "Non-nil when POS falls inside one of the excluded REGIONS.
Linear over REGIONS; `--scan' uses an advancing cursor instead (openers
are swept in order), so this is kept only for ad-hoc / external callers."
  (seq-some (lambda (r) (and (>= pos (car r)) (< pos (cdr r)))) regions))

(defun latex-to-svg-frontend--opener-environment (tok)
  "Return the environment name in a `\\begin{ENV}' opener TOK, or nil."
  (and (string-match "\\`\\\\begin{\\([A-Za-z0-9*]+\\)}\\'" tok)
       (match-string 1 tok)))

(defun latex-to-svg-frontend--environment-enabled-p (env)
  "Non-nil when ENV is one of `latex-to-svg-frontend-environments'.
A trailing `*' is ignored, so listing \"equation\" also enables `equation*';
an explicitly starred entry in the list still matches as written."
  (and env
       (or (eq latex-to-svg-frontend-environments t)
           (member env latex-to-svg-frontend-environments)
           (member (replace-regexp-in-string "\\*\\'" "" env)
                   latex-to-svg-frontend-environments))))

(defun latex-to-svg-frontend--indentation-only-before-p (pos)
  "Non-nil when nothing but whitespace precedes POS on its line."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward " \t")
    (bolp)))

(defun latex-to-svg-frontend--family-enabled-p (tok)
  "Non-nil when opener TOK's delimiter family is enabled by its `-detect-*' toggle."
  (cond
   ((equal tok "$$") latex-to-svg-frontend-detect-dollar-display)
   ((equal tok "$") latex-to-svg-frontend-detect-dollar-inline)
   ((equal tok "\\[") latex-to-svg-frontend-detect-bracket-display)
   ((equal tok "\\(") latex-to-svg-frontend-detect-bracket-inline)
   ((string-prefix-p "\\begin{" tok)
    (and latex-to-svg-frontend-detect-environments
         (latex-to-svg-frontend--environment-enabled-p
          (latex-to-svg-frontend--opener-environment tok))))
   ((or (string-prefix-p "\\eqref{" tok) (string-prefix-p "\\ref{" tok))
    latex-to-svg-frontend-detect-references)
   (t t)))

(defun latex-to-svg-frontend--block-end (pos)
  "Return the end of the non-blank block containing POS.
A LaTeX math span may not contain a blank line, so the block boundary
\(the next `^[ \t]*$' line, or `point-max') caps any close search — an
unbalanced opener can never run away past the paragraph it lives in."
  (save-excursion
    (goto-char pos)
    (if (re-search-forward "\n[ \t]*\n" nil t)
        (match-beginning 0)
      (point-max))))

(defun latex-to-svg-frontend--block-bounds (pos)
  "Return (BEG . END) of the blank-line-delimited block containing POS."
  (save-excursion
    (let ((beg (progn (goto-char pos)
                      (if (re-search-backward "\n[ \t]*\n" nil t)
                          (match-end 0) (point-min))))
          (end (progn (goto-char pos)
                      (if (re-search-forward "\n[ \t]*\n" nil t)
                          (match-beginning 0) (point-max)))))
      (cons beg end))))

(defun latex-to-svg-frontend--find-dollar-close (from limit)
  "Return the position just after the closing `$' of an inline span, or nil.
FROM is the position right after the opening `$'; the search is bounded by
LIMIT (the block end).  The first `$' after FROM ends the span, as in TeX,
skipping an escaped `\\$' and a `$$'.  It closes the span only if no
whitespace precedes it and no digit follows it (pandoc's guards against
currency dollars); otherwise there is no span, so a currency `$' never
pairs with a `$' further on, such as the opening `$' of an equation."
  (save-excursion
    (goto-char from)
    (catch 'done
      (while (re-search-forward "\\$" limit t)
        (let ((p (match-beginning 0))
              (after (char-after (match-end 0))))
          (cond
           ((latex-to-svg-frontend--escaped-p p) nil) ; \$, keep looking
           ((eq after ?$)                                 ; part of a $$
            (goto-char (1+ (match-end 0))))
           ((or (memq (char-before p) '(?\s ?\t ?\n))    ; " $" not a close
                (and after (<= ?0 after ?9)))             ; "$2" not a close
            (throw 'done nil))
           (t (throw 'done (match-end 0))))))
      nil)))

(defun latex-to-svg-frontend--find-env-close (from env limit)
  "Return the position after the `\\end{ENV}' matching a `\\begin{ENV}', or nil.
FROM is the position right after the opening `\\begin{ENV}'; LIMIT (the
block end) bounds the search.  Handles nested environments of the same
ENV name."
  (save-excursion
    (goto-char from)
    (let ((re (concat "\\\\\\(begin\\|end\\){" (regexp-quote env) "}"))
          (depth 1))
      (catch 'done
        (while (re-search-forward re limit t)
          (if (equal (match-string 1) "begin")
              (setq depth (1+ depth))
            (setq depth (1- depth))
            (when (= depth 0) (throw 'done (match-end 0)))))
        nil))))

(defun latex-to-svg-frontend--match-span (mb me tok)
  "Return the math record for opener TOK found at MB..ME, or nil if unterminated.
Every close search is capped at the block end (`--block-end'), so a math
span can never cross a blank line — half-typed math yields nil rather than
swallowing later text."
  (let ((limit (latex-to-svg-frontend--block-end me)))
    (cond
     ((equal tok "$$")
      (save-excursion
        (goto-char me)
        (when (search-forward "$$" limit t)
          (latex-to-svg-frontend--math-make
           :type 'fragment :begin mb :end (point)
           :value (buffer-substring-no-properties mb (point))))))
     ((equal tok "$")
      (let ((after (char-after me)))
        (when (and after (not (memq after '(?\s ?\t ?\n))))
          (when-let* ((close (latex-to-svg-frontend--find-dollar-close me limit)))
            (latex-to-svg-frontend--math-make
             :type 'fragment :begin mb :end close
             :value (buffer-substring-no-properties mb close))))))
     ((equal tok "\\[")
      (save-excursion
        (goto-char me)
        (when (search-forward "\\]" limit t)
          (latex-to-svg-frontend--math-make
           :type 'fragment :begin mb :end (point)
           :value (buffer-substring-no-properties mb (point))))))
     ((equal tok "\\(")
      (save-excursion
        (goto-char me)
        (when (search-forward "\\)" limit t)
          (latex-to-svg-frontend--math-make
           :type 'fragment :begin mb :end (point)
           :value (buffer-substring-no-properties mb (point))))))
     ((string-prefix-p "\\begin{" tok)
      (let* ((env (and (string-match "{\\([A-Za-z0-9*]+\\)}" tok)
                       (match-string 1 tok)))
             (close (and env (latex-to-svg-frontend--find-env-close me env limit))))
        (when close
          (latex-to-svg-frontend--math-make
           :type 'environment :begin mb :end close
           :value (buffer-substring-no-properties mb close)))))
     ((or (string-prefix-p "\\eqref{" tok) (string-prefix-p "\\ref{" tok))
      (latex-to-svg-frontend--math-make
       :type 'fragment :begin mb :end me :value tok)))))

(defun latex-to-svg-frontend--scan (&optional beg end)
  "Return LaTeX math records within BEG..END (default whole buffer), in order.
Skips openers inside excluded regions (`--exclusions'), backslash-escaped
openers, and any delimiter family disabled by its `-detect-*' toggle.
Passing a small BEG..END (e.g. one blank-line block) keeps scans cheap."
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         ;; Exclusion regions sorted by start.  Since openers are swept in
         ;; increasing position, a monotonic cursor (CI) over this vector
         ;; decides "inside code?" in O(1) amortized, making the scan
         ;; O(openers + regions) instead of O(openers * regions).  Sorting by
         ;; start alone is enough even for nested / overlapping regions: the
         ;; first region whose end is past MB is the only one that can cover MB
         ;; (see the correctness note below).
         (codes (vconcat (sort (latex-to-svg-frontend--exclusions beg end)
                               (lambda (a b) (< (car a) (car b))))))
         (ncodes (length codes))
         (ci 0)
         (result '()))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char beg)
        (while (re-search-forward latex-to-svg-frontend--opener-regexp end t)
          (let ((mb (match-beginning 0))
                (me (match-end 0))
                (tok (match-string 0)))
            ;; Drop regions that end at or before MB; they cannot cover it or
            ;; any later (rightward) opener.  Whatever remains at CI is the
            ;; first region ending past MB — the sole candidate to contain MB.
            (while (and (< ci ncodes) (<= (cdr (aref codes ci)) mb))
              (setq ci (1+ ci)))
            (cond
             ((and (< ci ncodes) (>= mb (car (aref codes ci)))) ; MB inside code
              (goto-char me))
             ((latex-to-svg-frontend--escaped-p mb) (goto-char me))
             ;; `\begin{ENV}' opens a block-level environment, so it must start
             ;; its own line (indentation allowed).  A `\begin' after prose on
             ;; the same line is text about LaTeX, not a preview.
             ((and (string-prefix-p "\\begin{" tok)
                   (not (latex-to-svg-frontend--indentation-only-before-p mb)))
              (goto-char me))
             ((not (latex-to-svg-frontend--family-enabled-p tok)) (goto-char me))
             (t
              (let ((span (latex-to-svg-frontend--match-span mb me tok)))
                (if span
                    (progn (push span result)
                           (goto-char (latex-to-svg-frontend--math-end span)))
                  (goto-char me)))))))))
    (nreverse result)))

(defun latex-to-svg-frontend--detect (beg end)
  "Return math records within BEG..END using the active detector.
Defaults to the built-in scanner (`--scan'); a buffer-local
`latex-to-svg-frontend-detect-function' overrides it entirely (escape hatch)."
  (if latex-to-svg-frontend-detect-function
      (funcall latex-to-svg-frontend-detect-function beg end)
    (latex-to-svg-frontend--scan beg end)))

(defun latex-to-svg-frontend--environments ()
  "Return the environment records of the buffer, in document order."
  (seq-filter (lambda (m) (eq (latex-to-svg-frontend--math-type m) 'environment))
              (latex-to-svg-frontend--detect (point-min) (point-max))))

(defun latex-to-svg-frontend--elements (beg end)
  "Return the math records whose span overlaps BEG..END."
  (seq-filter (lambda (m)
                (and (< (latex-to-svg-frontend--math-begin m) end)
                     (> (latex-to-svg-frontend--math-end m) beg)))
              (latex-to-svg-frontend--detect (point-min) (point-max))))

(defun latex-to-svg-frontend--element-at (pos)
  "Return the math record covering POS, or nil.
Scans only the blank-line-delimited block around POS, so it is cheap
enough to run on every command (see `--handle-cursor')."
  (let ((bounds (latex-to-svg-frontend--block-bounds pos)))
    (seq-find (lambda (m)
                (and (<= (latex-to-svg-frontend--math-begin m) pos)
                     (<= pos (latex-to-svg-frontend--math-end m))))
              (latex-to-svg-frontend--detect (car bounds) (cdr bounds)))))

(defun latex-to-svg-frontend--element-bounds (el)
  "Return (BEG . END) covering EL's source text."
  (cons (latex-to-svg-frontend--math-begin el)
        (latex-to-svg-frontend--math-end el)))

;;;; Overlays

(defun latex-to-svg-frontend--center-prefix (ov image)
  "Return a centering `before-string' for IMAGE on OV, or nil.
Nil unless `latex-to-svg-frontend-center-display-math' is on and OV is
display math -- inline math belongs in the run of text.

The string is one space whose `display' is a stretch reaching to the window
center less half the image: `(space :align-to (- center (0.5 . IMAGE)))'.
Redisplay evaluates that expression, so the indent tracks
the window width, a split and the font with no help from us -- and
nothing measures the image, which is what `image-size' would have had
to do (see `latex-to-svg-backend' on why measuring an SVG is not
reliable)."
  (when (and latex-to-svg-frontend-center-display-math
             image
             (overlay-get ov 'latex-to-svg-frontend-display-math))
    (propertize " " 'display `(space :align-to (- center (0.5 . ,image))))))

(defun latex-to-svg-frontend--space-before (ov)
  "Return (BEG . END) of the spaces and tabs just before OV, or nil.
Nil also when nothing but spaces and tabs precedes OV on its line."
  (save-excursion
    (goto-char (overlay-start ov))
    (let ((end (point)))
      (skip-chars-backward " \t" (line-beginning-position))
      (and (< (point) end)
           (not (bolp))
           (cons (point) end)))))

(defun latex-to-svg-frontend--space-after (ov)
  "Return (BEG . END) of the first spaces and tabs after OV, or nil.
They are searched for on the line OV ends on.  Nil when no text follows
them on that line: the newline ending the line breaks it already."
  (save-excursion
    (goto-char (overlay-end ov))
    (skip-chars-forward "^ \t\n")
    (let ((beg (point)))
      (skip-chars-forward " \t")
      (and (< beg (point))
           (not (eolp))
           (cons beg (point))))))

(defun latex-to-svg-frontend--line-breaks (ov)
  "Return the spans to show as line breaks around OV's image.
A list of (BEG . END), each a run of spaces and tabs.  A `display'
property replaces the newlines of the text it covers, so:
- inline math whose source spans lines, as in a paragraph filled with
  hard line breaks, would join the line holding the equation and the
  line after it;
- display math with text before or after it on the lines of its
  delimiters would have that text beside the image.
The break goes where a fill would put it: at the first spaces after
the equation, so that punctuation attached to it stays on the image's
line, and, for display math, at the spaces before it."
  (let ((display (overlay-get ov 'latex-to-svg-frontend-display-math)))
    (delq nil
          (list (and display (latex-to-svg-frontend--space-before ov))
                (and (or display
                         (save-excursion
                           (goto-char (overlay-start ov))
                           (search-forward "\n" (overlay-end ov) t)))
                     (latex-to-svg-frontend--space-after ov))))))

(defun latex-to-svg-frontend--delete-line-breaks (ov)
  "Delete the line-break overlays of OV."
  (mapc #'delete-overlay (overlay-get ov 'latex-to-svg-frontend-line-breaks))
  (overlay-put ov 'latex-to-svg-frontend-line-breaks nil))

(defun latex-to-svg-frontend--show-line-breaks (ov)
  "Show the spans `latex-to-svg-frontend--line-breaks' finds as newlines.
Each span gets an overlay with `display' \"\\n\", recorded on OV, which
owns it: it is deleted with OV's image.  These overlays do not carry
the `latex-to-svg-frontend' property, so code looking for previews
does not see them."
  (latex-to-svg-frontend--delete-line-breaks ov)
  (overlay-put ov 'latex-to-svg-frontend-line-breaks
               (mapcar (lambda (span)
                         (let ((o (make-overlay (car span) (cdr span))))
                           (overlay-put o 'display "\n")
                           (overlay-put o 'evaporate t)
                           o))
                       (latex-to-svg-frontend--line-breaks ov))))

(defun latex-to-svg-frontend--redraw-table (ov)
  "Have pretty-tables draw again the table row OV is in, if it is in one.
pretty-tables draws a table row from what its cells display when
jit-lock reaches it, so an image shown after that is not in the
drawing.  Its row overlays have the property `pretty-tables', and
`jit-lock-refontify' has the table drawn again at the next redisplay.
The text is marked from the start of the row overlay, not of OV:
redisplay does not reach the text under a drawn row, whose overlay
displays the row in its place, but it does stop at the overlay's
start and runs jit-lock there."
  (when-let* ((row (seq-find (lambda (o) (overlay-get o 'pretty-tables))
                             (overlays-at (overlay-start ov)))))
    (jit-lock-refontify (overlay-start row) (overlay-end ov))))

(defun latex-to-svg-frontend--show-image (ov image)
  "Show IMAGE on OV, centered if it is display math and centering is on.
The centering prefix embeds IMAGE, so it is rebuilt here rather than
kept across a re-render: every path that shows an image goes through
this function, and `latex-to-svg-frontend--hide-image' undoes it.  So
are the line breaks around the image (see
`latex-to-svg-frontend--line-breaks').  The image carries its width in
pixels as `:width', with which pretty-tables draws a table cell holding
it; see `latex-to-svg-frontend--redraw-table'."
  (overlay-put ov 'display image)
  (overlay-put ov 'before-string
               (latex-to-svg-frontend--center-prefix ov image))
  (latex-to-svg-frontend--show-line-breaks ov)
  (latex-to-svg-frontend--redraw-table ov))

(defun latex-to-svg-frontend--hide-image (ov)
  "Hide OV's image, revealing its LaTeX source.
Drops the centering prefix and the line breaks with it, so revealed
source is not indented by a leftover stretch."
  (overlay-put ov 'display nil)
  (overlay-put ov 'before-string nil)
  (latex-to-svg-frontend--delete-line-breaks ov))

(defun latex-to-svg-frontend--delete-overlay (ov)
  "Delete the preview overlay OV and its line-break overlays."
  (latex-to-svg-frontend--delete-line-breaks ov)
  (delete-overlay ov))

(defun latex-to-svg-frontend--overlays-in (beg end)
  "Return this package's overlays intersecting BEG..END."
  (seq-filter (lambda (o) (overlay-get o 'latex-to-svg-frontend))
              (overlays-in beg end)))

(defun latex-to-svg-frontend--clear-region (beg end)
  "Delete this package's preview overlays intersecting BEG..END."
  (mapc #'latex-to-svg-frontend--delete-overlay
        (latex-to-svg-frontend--overlays-in beg end)))

(defun latex-to-svg-frontend--help-echo-text (latex)
  "Return LATEX quoted so that `help-echo' shows it as written.
Emacs passes a `help-echo' string through `substitute-command-keys'
before showing it, which reads `\\=\\[' as the start of a key reference,
`\\=\\{' as a keymap, and turns quotes into curved ones: `\\=\\[x=1\\=\\]'
would show as the key binding of a command named \"x=1\\\".  A `\\=\\='
before each backslash, backquote and apostrophe makes
`substitute-command-keys' copy it literally."
  (replace-regexp-in-string "[\\`']" "\\\\=\\&" latex))

(defun latex-to-svg-frontend--engine-name (engine)
  "Return the name of ENGINE for display: \"LaTeX\", \"RaTeX\" or \"texres\"."
  (pcase engine
    ('ratex "RaTeX")
    ('texres "texres")
    (_ "LaTeX")))

(defun latex-to-svg-frontend--help-echo (value source engine fallback)
  "Return the `help-echo' of a preview of SOURCE, sent as VALUE.
It names the engine that typeset the picture, then shows SOURCE:
\"Typeset with RaTeX: SOURCE\".  ENGINE and FALLBACK are the ones VALUE
was sent with; when the picture came from FALLBACK, because ENGINE
could not typeset VALUE (see `latex-to-svg-backend-engine-used'), it
says so: \"Typeset with LaTeX (RaTeX could not parse it): SOURCE\"."
  (let* ((engine (or engine 'latex))
         (used (or (latex-to-svg-backend-engine-used value engine fallback)
                   engine)))
    (concat (if (eq used engine)
                (format "Typeset with %s"
                        (latex-to-svg-frontend--engine-name used))
              (format "Typeset with %s (%s could not parse it)"
                      (latex-to-svg-frontend--engine-name used)
                      (latex-to-svg-frontend--engine-name engine)))
            ": "
            (latex-to-svg-frontend--help-echo-text source))))

(defun latex-to-svg-frontend--set-overlay (beg end value image &optional source enums-fallback display-p engine fallback)
  "Overlay BEG..END (positions or markers) with IMAGE, keyed to render VALUE.
VALUE is the exact string handed to the backend (a numbered environment
carries its `\\setcounter' prefix); SOURCE, if given, is the human-readable
LaTeX shown in `help-echo'.  ENUMS-FALLBACK, when non-nil, marks this as a
numbered equation and records its (INITIAL . FINAL) number range in
`latex-to-svg-frontend-enums'.  ENGINE and FALLBACK are the engine and
fallback engine VALUE was sent with, recorded so a refresh fetches the
same cache entry.  Replaces any existing preview overlay in the span."
  (let ((b (if (markerp beg) (marker-position beg) beg))
        (e (if (markerp end) (marker-position end) end)))
    (when (and b e (< b e) (<= (point-min) b) (<= e (point-max)))
      (latex-to-svg-frontend--clear-region b e)
      (let ((ov (make-overlay b e)))
        (overlay-put ov 'latex-to-svg-frontend t)
        (overlay-put ov 'latex-to-svg-frontend-value value)
        (overlay-put ov 'latex-to-svg-frontend-engine engine)
        (overlay-put ov 'latex-to-svg-frontend-fallback fallback)
        ;; Raw LaTeX (no `\setcounter' prefix) so a numbered overlay can be
        ;; renumbered from itself, without re-scanning buffer text.
        (overlay-put ov 'latex-to-svg-frontend-source (or source value))
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'help-echo
                     (latex-to-svg-frontend--help-echo
                      value (or source value) engine fallback))
        ;; Keep markup font-lock (Org emphasis, ...) from drawing a
        ;; strike-through / underline across the rendered image.
        (overlay-put ov 'face latex-to-svg-frontend--neutralize-face)
        (overlay-put ov 'priority 1)
        (overlay-put ov 'latex-to-svg-frontend-display-math display-p)
        (overlay-put ov 'latex-to-svg-frontend-image image)
        ;; After `display-math', which decides whether it is centered.
        (latex-to-svg-frontend--show-image ov image)
        (when enums-fallback
          (let ((meta (plist-get (latex-to-svg-backend-metadata value engine) :nums)))
            (overlay-put ov 'latex-to-svg-frontend-enums (or meta enums-fallback))
            (when (and meta (not (equal meta enums-fallback)))
              (latex-to-svg-frontend--schedule-reconcile))))
        (overlay-put ov 'modification-hooks
                     (list #'latex-to-svg-frontend--on-modify))
        (setq latex-to-svg-frontend--rendered-appearance
              (latex-to-svg-frontend--appearance))
        ov))))

(defun latex-to-svg-frontend--set-unrendered-overlay (beg end source enums-fallback engine)
  "Mark BEG..END as math whose cookie leaves it unrendered.
ENGINE is `skip', or a warning string (see `--engine-for'), which is
shown with `display-warning' and as the overlay's `help-echo'.  The
overlay shows nothing: the source stays as text.  It keeps SOURCE and,
when ENUMS-FALLBACK is non-nil, the equation's number range, so the
incremental renumbering counts the numbers a skipped equation takes, as
the exported document does.  Leaving it after an edit re-renders it."
  (let ((b (if (markerp beg) (marker-position beg) beg))
        (e (if (markerp end) (marker-position end) end)))
    (when (and b e (< b e) (<= (point-min) b) (<= e (point-max)))
      (latex-to-svg-frontend--clear-region b e)
      (let ((ov (make-overlay b e)))
        (overlay-put ov 'latex-to-svg-frontend t)
        (overlay-put ov 'latex-to-svg-frontend-unrendered t)
        (overlay-put ov 'latex-to-svg-frontend-source source)
        (overlay-put ov 'latex-to-svg-frontend-engine engine)
        (overlay-put ov 'evaporate t)
        (when enums-fallback
          (overlay-put ov 'latex-to-svg-frontend-enums enums-fallback))
        (when (stringp engine)
          (overlay-put ov 'help-echo engine)
          (display-warning 'latex-to-svg-frontend
                           (format "%s, line %d: %s" (buffer-name)
                                   (line-number-at-pos b) engine)))
        (overlay-put ov 'modification-hooks
                     (list #'latex-to-svg-frontend--on-modify))
        ov))))

;;;; Reveal on cursor entry

(defvar-local latex-to-svg-frontend--last-point nil
  "Marker at point after the previous command (for cursor reveal tracking).")

(defun latex-to-svg-frontend--on-modify (ov after &rest _)
  "Modification hook for preview overlay OV.
AFTER is non-nil after the change; reveal OV's source and flag it for
re-render."
  (when after
    (overlay-put ov 'latex-to-svg-frontend-modified t)
    (latex-to-svg-frontend--hide-image ov)))

(defun latex-to-svg-frontend--revealable-overlay-at (pos)
  "Return this package's preview overlay covering POS, or nil.
Image previews, `\\eqref' / `\\ref' text previews and unrendered math
\(see `--set-unrendered-overlay') qualify."
  (seq-find (lambda (o) (or (overlay-get o 'latex-to-svg-frontend-image)
                            (overlay-get o 'latex-to-svg-frontend-ref)
                            (overlay-get o 'latex-to-svg-frontend-unrendered)))
            (overlays-at pos)))

(defun latex-to-svg-frontend--reveal-p ()
  "Non-nil if the preview point is on is shown as its LaTeX source.
That is when `latex-to-svg-frontend-reveal' says so, or during an
Isearch."
  (or isearch-mode
      (pcase latex-to-svg-frontend-reveal
        ('always t)
        ('writable (not buffer-read-only)))))

(defun latex-to-svg-frontend--open-overlay (ov)
  "Reveal OV's LaTeX source by hiding its image / reference text."
  (latex-to-svg-frontend--hide-image ov))

(defun latex-to-svg-frontend--close-overlay (ov)
  "Re-show OV's preview, or re-render it if its source was edited while open."
  (when (overlay-buffer ov)
    (cond
     ((overlay-get ov 'latex-to-svg-frontend-modified)
      (overlay-put ov 'latex-to-svg-frontend-modified nil)
      (latex-to-svg-frontend--rerender-overlay ov))
     ((overlay-get ov 'latex-to-svg-frontend-image)
      (latex-to-svg-frontend--show-image
       ov (overlay-get ov 'latex-to-svg-frontend-image)))
     ((overlay-get ov 'latex-to-svg-frontend-ref)
      (overlay-put ov 'display (overlay-get ov 'latex-to-svg-frontend-ref-display))))))

(defun latex-to-svg-frontend--render-on-leave-element (el)
  "Render EL on cursor-leave and renumber synchronously from it.
Cursor-leave is a discrete event, so we reconcile now, not on the
debounced backstop.  When `latex-to-svg-frontend-incremental-reconcile'
is on, EL is numbered from the preceding overlay and only the equations
below it are re-threaded (`--reconcile-from'); otherwise a full scan."
  (if latex-to-svg-frontend-incremental-reconcile
      (progn
        (latex-to-svg-frontend--render-element
         el (latex-to-svg-frontend--local-table el))
        (latex-to-svg-frontend--reconcile-from
         (latex-to-svg-frontend--math-begin el))
        ;; This incremental pass covered the left equation and everything
        ;; below it.  If no text changed outside its span, the pending
        ;; whole-buffer catch-up is redundant, so drop it.
        (latex-to-svg-frontend--maybe-cancel-reconcile
         (latex-to-svg-frontend--math-begin el)
         (latex-to-svg-frontend--math-end el)))
    ;; The full reconcile is comprehensive and already cancelled the pending
    ;; pass; nothing more to do.
    (latex-to-svg-frontend--render-element el)
    (latex-to-svg-frontend--reconcile)))

(defun latex-to-svg-frontend--rerender-overlay (ov)
  "Re-render the math element under OV after an edit; else drop OV."
  (when-let* ((start (overlay-start ov)))
    (let ((el (latex-to-svg-frontend--element-at start)))
      (if (and el (memq (latex-to-svg-frontend--math-type el)
                        latex-to-svg-frontend--element-types))
          (latex-to-svg-frontend--render-on-leave-element el)
        (latex-to-svg-frontend--delete-overlay ov)))))

(defun latex-to-svg-frontend--render-on-leave (from to)
  "Render the math element FROM was inside, once TO has left its span.
This is how newly typed math appears: a complete, not-yet-rendered
element is compiled the moment the cursor leaves it (never while still
inside, so half-typed math is not compiled).  Because `--element-at' is
blank-line-bounded, an incomplete opener has no element yet and nothing
happens until it is closed and left."
  (when-let* ((el (latex-to-svg-frontend--element-at from)))
    (let ((b (latex-to-svg-frontend--math-begin el))
          (e (latex-to-svg-frontend--math-end el)))
      (when (and (or (< to b) (> to e))
                 (not (latex-to-svg-frontend--overlays-in b e)))
        ;; A new equation can shift every number below it.  Leaving it is a
        ;; discrete event, so renumber synchronously (the debounced
        ;; `--schedule-reconcile' is only the after-change backstop for edits
        ;; with no clean leave: delete, paste, undo).
        (latex-to-svg-frontend--render-on-leave-element el)))))

(defun latex-to-svg-frontend--handle-cursor ()
  "Handle a cursor move around math previews.
Reveal the preview point moved into, re-hide the one it left, and render
any newly finished equation the cursor just left.
On `post-command-hook' while the mode is on."
  (when latex-to-svg-frontend-mode
    (let ((last (and latex-to-svg-frontend--last-point
                     (marker-position latex-to-svg-frontend--last-point))))
      ;; Render an equation the cursor just left (event-driven, no idle timer).
      (when (and last (/= last (point)))
        (latex-to-svg-frontend--render-on-leave last (point)))
      (let* ((prev (and last (latex-to-svg-frontend--revealable-overlay-at last)))
             (cur (latex-to-svg-frontend--revealable-overlay-at (point)))
             (reveal (latex-to-svg-frontend--reveal-p)))
      ;; Close the preview point left.  Also close the one point stays on
      ;; once revealing stops, as when an Isearch ends in a read-only
      ;; buffer; never an edited one, which re-renders only on leave.
      (when (and prev
                 (or (not (eq prev cur))
                     (and (not reveal)
                          (null (overlay-get prev 'display))
                          (not (overlay-get prev 'latex-to-svg-frontend-modified)))))
        (latex-to-svg-frontend--close-overlay prev))
      ;; A reference reached by *mouse* is never revealed: a click there is a
      ;; jump, not an edit.  This is not just taste -- it is required for
      ;; `follow-link' to work at all.  Emacs classifies a button press+release
      ;; as a click only if the pixel movement is under `double-click-fuzz'
      ;; *and* the buffer position under the pointer is unchanged (keyboard.c,
      ;; `make_lispy_event').  Revealing on the press replaces the "(1)" glyph
      ;; with the wider `\eqref{...}' source, so the same pixel maps to a
      ;; different position and the release is reported as `drag-mouse-1' --
      ;; which never follows a link.  Point-motion reveal stays for the
      ;; keyboard, which is where editing intent actually comes from.
      (when (and cur reveal (not (eq cur prev))
                 (not (and (overlay-get cur 'latex-to-svg-frontend-ref)
                           (mouse-event-p last-command-event))))
        (latex-to-svg-frontend--open-overlay cur))
      (unless latex-to-svg-frontend--last-point
        (setq latex-to-svg-frontend--last-point (make-marker)))
      (set-marker latex-to-svg-frontend--last-point (point))))))

(defun latex-to-svg-frontend--heal-modified ()
  "Re-render previews that were edited and then left by point."
  (dolist (ov (latex-to-svg-frontend--overlays-in (point-min) (point-max)))
    (when (and (overlay-get ov 'latex-to-svg-frontend-modified)
               (or (< (point) (overlay-start ov))
                   (> (point) (overlay-end ov))))
      (overlay-put ov 'latex-to-svg-frontend-modified nil)
      (latex-to-svg-frontend--rerender-overlay ov))))

(defun latex-to-svg-frontend--set-reference-overlay (beg end label num display)
  "Overlay BEG..END with plain-text DISPLAY for a reference to LABEL.
NUM is the resolved number, recorded so a reconcile can detect when the
target renumbered.  Draws ordinary buffer text (matching the prose font)
and makes the span jump, on `mouse-2' (or a short `mouse-1' click, via
`follow-link') or \\<latex-to-svg-frontend--reference-keymap>\\[latex-to-svg-frontend-goto-reference], to the equation
defining LABEL."
  (let ((b (if (markerp beg) (marker-position beg) beg))
        (e (if (markerp end) (marker-position end) end)))
    (when (and b e (< b e) (<= (point-min) b) (<= e (point-max)))
      (latex-to-svg-frontend--clear-region b e)
      (let ((ov (make-overlay b e)))
        (overlay-put ov 'latex-to-svg-frontend t)
        (overlay-put ov 'latex-to-svg-frontend-ref label)
        (overlay-put ov 'latex-to-svg-frontend-ref-num num)
        (overlay-put ov 'latex-to-svg-frontend-ref-display display)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'display display)
        (overlay-put ov 'face latex-to-svg-frontend--neutralize-face)
        (overlay-put ov 'priority 1)
        (overlay-put ov 'keymap latex-to-svg-frontend--reference-keymap)
        (overlay-put ov 'mouse-face 'highlight)
        ;; Phrased as mouse-2: `mouse-fixup-help-message' rewrites it to
        ;; "mouse-1" / "double-mouse-1" / "Long mouse-1" to match the user's
        ;; `mouse-1-click-follows-link' setting.
        (overlay-put ov 'help-echo
                     (format "mouse-2: jump to the equation labelled %s" label))
        (overlay-put ov 'modification-hooks
                     (list #'latex-to-svg-frontend--on-modify))
        ov))))

;;;; Numbering

(defconst latex-to-svg-frontend--unnumbered-regexp
  "\\\\nonumber\\|\\\\notag\\|\\\\tag{"
  "Regexp matching what keeps an equation or a row from taking a number.")

(defun latex-to-svg-frontend--environment-name (value)
  "Return the LaTeX environment name at the start of source VALUE, or nil."
  (and (string-match "\\`[ \t\n]*\\\\begin{\\([^}]+\\)}" value)
       (match-string 1 value)))

(defun latex-to-svg-frontend--count-multi-rows (value env)
  "Count numbered rows in multi-equation environment source VALUE named ENV."
  (with-temp-buffer
    (insert value)
    (goto-char (point-min))
    (when (re-search-forward (concat "\\\\begin{" (regexp-quote env) "}") nil t)
      (delete-region (point-min) (point)))
    (goto-char (point-max))
    (when (re-search-backward (concat "\\\\end{" (regexp-quote env) "}") nil t)
      (delete-region (match-beginning 0) (point-max)))
    (goto-char (point-min))
    (while (re-search-forward "\\\\end{\\([^}]+\\)}" nil t)
      (let ((name (match-string 1))
            (eto (match-end 0))
            (efrom (match-beginning 0)))
        (goto-char efrom)
        (if (re-search-backward (concat "\\\\begin{" (regexp-quote name) "}") nil t)
            (progn (delete-region (match-beginning 0) eto)
                   (goto-char (match-beginning 0)))
          (goto-char eto))))
    (let ((rows 1) (suppressed 0))
      (goto-char (point-min))
      (while (re-search-forward "\\\\\\\\" nil t) (cl-incf rows))
      (goto-char (point-min))
      (while (re-search-forward latex-to-svg-frontend--unnumbered-regexp nil t)
        (cl-incf suppressed))
      (max 0 (- rows suppressed)))))

(defun latex-to-svg-frontend--count-numbered-equations (value)
  "Return how many numbered equations the environment source VALUE consumes.
Unknown / non-numbered environments (and starred forms) consume 0."
  (let ((env (latex-to-svg-frontend--environment-name value)))
    (cond
     ((member env latex-to-svg-frontend--numbered-environments-single)
      (if (string-match-p latex-to-svg-frontend--unnumbered-regexp value) 0 1))
     ((member env latex-to-svg-frontend--numbered-environments-multi)
      (latex-to-svg-frontend--count-multi-rows value env))
     (t 0))))

(defun latex-to-svg-frontend--labels-in (text)
  "Return the list of `\\label' names in TEXT, in document order."
  (let ((names nil) (start 0))
    (while (string-match "\\\\label{\\([^}]+\\)}" text start)
      (push (match-string 1 text) names)
      (setq start (match-end 0)))
    (nreverse names)))

(defun latex-to-svg-frontend--end-position (value env)
  "Return where the last `\\end{ENV}' in source VALUE starts, or nil."
  (let ((close (concat "\\\\end{" (regexp-quote env) "}"))
        (start 0) pos)
    (while (string-match close value start)
      (setq pos (match-beginning 0)
            start (match-end 0)))
    pos))

(defun latex-to-svg-frontend--multi-rows (value env)
  "Return the top-level rows of multi-equation source VALUE named ENV.
Each row is a cons (BEG . END) of positions in VALUE, in order.  END is
where the row's `\\\\' starts, or the closing `\\end{ENV}' for the
last row.  A `\\\\' inside a nested environment (`cases', `matrix', …)
does not end a row."
  (let* ((start (if (string-match (concat "\\\\begin{" (regexp-quote env) "}")
                                  value)
                    (match-end 0)
                  0))
         (end (or (latex-to-svg-frontend--end-position value env)
                  (length value)))
         (rows nil) (depth 0) (row-start start) (i start))
    (while (and (string-match "\\\\begin{[^}]+}\\|\\\\end{[^}]+}\\|\\\\\\\\"
                              value i)
                (< (match-beginning 0) end))
      (let ((m (match-string 0 value)))
        (cond
         ((string-prefix-p "\\begin" m) (cl-incf depth))
         ((string-prefix-p "\\end" m) (setq depth (max 0 (1- depth))))
         ((= depth 0)
          (push (cons row-start (match-beginning 0)) rows)
          (setq row-start (match-end 0)))))
      (setq i (match-end 0)))
    (push (cons row-start end) rows)
    (nreverse rows)))

(defun latex-to-svg-frontend--multi-row-labels (value env offset)
  "Return an alist of (LABEL . NUMBER) for multi-equation source VALUE.
ENV is the environment name; OFFSET the counter before the block."
  (let ((num (1+ offset)) (out nil))
    (pcase-dolist (`(,beg . ,end) (latex-to-svg-frontend--multi-rows value env))
      (let ((row (substring value beg end)))
        (unless (string-match-p latex-to-svg-frontend--unnumbered-regexp row)
          (dolist (name (latex-to-svg-frontend--labels-in row))
            (push (cons name num) out))
          (cl-incf num))))
    (nreverse out)))

(defun latex-to-svg-frontend--scan-numbering (&optional environments)
  "Scan the widened buffer; return the cons (OFFSETS . LABELS).
OFFSETS maps a numbered environment's BEGIN to its counter offset; LABELS
maps a `\\label' name to its resolved equation number.
ENVIRONMENTS, when non-nil, is a pre-computed `--environments' list used
in place of a fresh scan, so one scan can be shared across passes."
  (let ((offsets (make-hash-table :test 'eql))
        (labels (make-hash-table :test 'equal))
        (offset 0))
    (dolist (el (or environments (latex-to-svg-frontend--environments)))
      (let* ((value (latex-to-svg-frontend--math-value el))
             (env (latex-to-svg-frontend--environment-name value)))
        (when (member env latex-to-svg-frontend--numbered-environments-all)
          (puthash (latex-to-svg-frontend--math-begin el) offset offsets)
          (let ((count (latex-to-svg-frontend--count-numbered-equations value)))
            (cond
             ((member env latex-to-svg-frontend--numbered-environments-single)
              (when (= count 1)
                (dolist (name (latex-to-svg-frontend--labels-in value))
                  (puthash name (1+ offset) labels))))
             ((member env latex-to-svg-frontend--numbered-environments-multi)
              (dolist (pair (latex-to-svg-frontend--multi-row-labels value env offset))
                (puthash (car pair) (cdr pair) labels))))
            (cl-incf offset count)))))
    (cons offsets labels)))

(defun latex-to-svg-frontend--numbering-table ()
  "Return only the BEGIN -> offset hash.
See `latex-to-svg-frontend--scan-numbering' for the full scan."
  (car (latex-to-svg-frontend--scan-numbering)))

(defun latex-to-svg-frontend--maybe-table ()
  "Return a fresh (OFFSETS . LABELS) scan when numbering is enabled, else nil.
Also installs `latex-to-svg-backend-metadata-prefix' so numbered compiles record
their final counter into the backend's `.eld' sidecar."
  (when latex-to-svg-frontend-number-equations
    (setq latex-to-svg-backend-metadata-prefix latex-to-svg-frontend--metadata-prefix)
    (latex-to-svg-frontend--scan-numbering)))

(defun latex-to-svg-frontend--reference-parse (source)
  "Parse SOURCE as a reference fragment; return (KIND . NAME) or nil.
KIND is \"eqref\" or \"ref\"; NAME is the label.  SOURCE may be bare or
wrapped in `$…$' / `\\(…\\)'."
  (let ((s (string-trim source)))
    (cond
     ((and (string-prefix-p "$" s) (string-suffix-p "$" s) (> (length s) 1))
      (setq s (string-trim (substring s 1 -1))))
     ((and (string-prefix-p "\\(" s) (string-suffix-p "\\)" s))
      (setq s (string-trim (substring s 2 -2)))))
    (when (string-match "\\`\\\\\\(eqref\\|ref\\){\\([^}]+\\)}\\'" s)
      (cons (match-string 1 s) (match-string 2 s)))))

(defun latex-to-svg-frontend--reference-labels (labels)
  "Return the table references resolve against, given the scan's LABELS.
That is the table `latex-to-svg-frontend-labels-function' returns when
it is set, else LABELS."
  (if latex-to-svg-frontend-labels-function
      (funcall latex-to-svg-frontend-labels-function)
    labels))

(defun latex-to-svg-frontend--reference-display (source labels)
  "If SOURCE is a resolvable `\\eqref' / `\\ref' fragment, return its display text.
The number is looked up in LABELS.
`\\eqref' -> \"(N)\", `\\ref' -> \"N\" — plain buffer text — or nil."
  (when-let* ((parsed (latex-to-svg-frontend--reference-parse source))
              (num (gethash (cdr parsed) labels)))
    (if (equal (car parsed) "eqref") (format "(%s)" num) (format "%s" num))))

(defun latex-to-svg-frontend--reference-display-text (kind num)
  "Return the buffer-text display for a KIND (\"eqref\"/\"ref\") reference to NUM.
NUM is an integer from the numbering scan or a string from
`latex-to-svg-frontend-labels-function'.  NUM nil (an unknown or
just-deleted target) shows \"(??)\" / \"??\" so a dangling reference is
visibly broken rather than stale."
  (propertize
   (cond ((null num) (if (equal kind "eqref") "(??)" "??"))
         ((equal kind "eqref") (format "(%s)" num))
         (t (format "%s" num)))
   'face 'latex-to-svg-frontend-reference))

(defun latex-to-svg-frontend--label-position (label)
  "Return the BEGIN of the math element defining LABEL, or nil."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (let ((needle (format "\\label{%s}" label)) pos)
        (while (and (not pos) (search-forward needle nil t))
          (let ((el (latex-to-svg-frontend--element-at (match-beginning 0))))
            (when (and el (memq (latex-to-svg-frontend--math-type el)
                                latex-to-svg-frontend--element-types))
              (setq pos (latex-to-svg-frontend--math-begin el)))))
        pos))))

(defun latex-to-svg-frontend--setcounter-value (k source)
  "Wrap SOURCE for numbered rendering starting at counter K.
Prefixes `\\setcounter{equation}{K}' and appends a `\\typeout' probe
emitting the block's final counter (captured into the `.eld' sidecar)."
  (format "\\setcounter{equation}{%d}%%\n%s\\typeout{%s\\arabic{equation}}%%\n"
          k source latex-to-svg-frontend--metadata-prefix))

(defun latex-to-svg-frontend--tagged-value (k source)
  "Number SOURCE from counter K with a `\\tag' on each numbered row.
RaTeX has no equation counter, so the numbers are written in: a
single-equation environment gets `\\tag{K+1}' before its `\\end', and
each top-level row of a multi-equation environment that is not
suppressed gets the next number before its `\\\\' (or the `\\end').
The numbers are the ones `--multi-row-labels' assigns, so the picture
and `\\eqref' agree.  Any other SOURCE is returned unchanged."
  (let ((env (latex-to-svg-frontend--environment-name source)))
    (cond
     ((member env latex-to-svg-frontend--numbered-environments-single)
      (let ((end (latex-to-svg-frontend--end-position source env)))
        (if (and end (= (latex-to-svg-frontend--count-numbered-equations source) 1))
            (concat (substring source 0 end)
                    (format "\\tag{%d}" (1+ k))
                    (substring source end))
          source)))
     ((member env latex-to-svg-frontend--numbered-environments-multi)
      (let ((num (1+ k)) (pos 0) (parts nil))
        (pcase-dolist (`(,beg . ,end) (latex-to-svg-frontend--multi-rows source env))
          (unless (string-match-p latex-to-svg-frontend--unnumbered-regexp
                                  (substring source beg end))
            (push (substring source pos end) parts)
            (push (format "\\tag{%d}" num) parts)
            (setq pos end)
            (cl-incf num)))
        (push (substring source pos) parts)
        (apply #'concat (nreverse parts))))
     (t source))))

(defconst latex-to-svg-frontend--cookie-regexp
  "%[ \t]*\\(?:latex-to-svg:[ \t]*\\)?\\([a-z]+\\)[ \t]*=[ \t]*\\([a-z]+\\)"
  "Regexp matching a cookie: `%', optionally `latex-to-svg:', then KEY=VALUE.
Group 1 is KEY and group 2 is VALUE.  Where a cookie may stand is
checked by `latex-to-svg-frontend--cookie'.")

(defconst latex-to-svg-frontend--cookie-opener-regexp
  (concat "\\`[ \t\n]*\\(?:"
          "\\\\begin{[^}]*}\\(?:{[^}\n]*}\\|\\[[^]\n]*\\]\\)*"
          "\\|\\\\\\[\\|\\$\\$\\)")
  "Regexp matching the opener of display math, with an environment's arguments.")

(defconst latex-to-svg-frontend--engine-cookie-values
  '(("latex" . latex) ("tex" . latex)
    ("ratex" . ratex)
    ("texres" . texres)
    ("skip" . skip) ("none" . skip))
  "The values of a `engine=' cookie, and what each one selects.")

(defun latex-to-svg-frontend--cookie-bounds (source)
  "Return the cookie of display math SOURCE as (KEY VALUE BEG END), or nil.
A cookie is a `%' comment before any math: on the opener line, with only
blanks (and an environment's arguments) between the opener and the `%',
or alone on the line right after a blank opener line.  A `%' comment
further down is an ordinary comment.

BEG..END is the text of SOURCE that removing the cookie deletes: on the
opener line, from after the opener to the end of the line, keeping the
newline; on its own line, that line and its newline.  Either way SOURCE
without it is what it would be had the cookie never been written."
  (let ((case-fold-search nil)
        (cookie (concat "\\`[ \t]*" latex-to-svg-frontend--cookie-regexp)))
    (when (string-match latex-to-svg-frontend--cookie-opener-regexp source)
      (let* ((start (match-end 0))
             (eol (or (string-search "\n" source start) (length source)))
             (line (substring source start eol))
             (next-eol (and (< eol (length source))
                            (or (string-search "\n" source (1+ eol))
                                (length source))))
             (next (and next-eol (substring source (1+ eol) next-eol))))
        (cond
         ((string-match cookie line)
          (list (match-string 1 line) (match-string 2 line) start eol))
         ((and next
               (string-match-p "\\`[ \t]*\\'" line)
               (string-match cookie next))
          (list (match-string 1 next) (match-string 2 next)
                (1+ eol) (min (1+ next-eol) (length source)))))))))

(defun latex-to-svg-frontend--cookie (source)
  "Return the cookie of display math SOURCE as (KEY . VALUE), or nil.
See `latex-to-svg-frontend--cookie-bounds' for where a cookie may stand."
  (when-let* ((bounds (latex-to-svg-frontend--cookie-bounds source)))
    (cons (nth 0 bounds) (nth 1 bounds))))

(defun latex-to-svg-frontend--remove-cookie (source)
  "Return SOURCE without its cookie, or SOURCE when it has none.
The cookie is an instruction to this package, not LaTeX, so it is not
sent to the backend: an equation with a cookie that selects the engine
it would get anyway shares the cache entry of the same equation written
without one.  See `latex-to-svg-frontend--cookie-bounds'."
  (if-let* (((latex-to-svg-frontend--display-p source))
            (bounds (latex-to-svg-frontend--cookie-bounds source)))
      (concat (substring source 0 (nth 2 bounds))
              (substring source (nth 3 bounds)))
    source))

(defun latex-to-svg-frontend--engine-for (source)
  "Return the engine for the equation whose LaTeX is SOURCE.
Display math can choose its engine with a cookie (see
`latex-to-svg-frontend--cookie'); without one, the engine is
`latex-to-svg-frontend-engine'.  The result is `latex', `ratex' or
`texres'; `skip' for `engine=skip' or `engine=none'; or a string, the
warning for an unknown key or value.  For `skip' and a string, nothing
is sent to the backend.  A program of the engine that is not found is
the backend's to report."
  (let ((cookie (and (latex-to-svg-frontend--display-p source)
                     (latex-to-svg-frontend--cookie source))))
    (if (null cookie)
        latex-to-svg-frontend-engine
      (let ((engine (cdr (assoc (cdr cookie)
                                  latex-to-svg-frontend--engine-cookie-values))))
        (cond
         ((not (equal (car cookie) "engine"))
          (format "Unknown key `%s' in cookie `%%%s=%s'"
                  (car cookie) (car cookie) (cdr cookie)))
         ((null engine)
          (format "Unknown value `%s' in cookie `%% engine=%s' (known: %s)"
                  (cdr cookie) (cdr cookie)
                  (mapconcat #'car latex-to-svg-frontend--engine-cookie-values
                             ", ")))
         (t engine))))))

(defun latex-to-svg-frontend--backend-value (k source engine)
  "Return the string handed to the backend for SOURCE, numbered from K.
ENGINE is the engine that typesets it.  K is the counter before SOURCE;
nil means SOURCE is not numbered.  The cookie, if any, is removed first
\(see `--remove-cookie').  For `latex' and `texres', a numbered SOURCE
then gets `--setcounter-value' and any other SOURCE is passed as it is.  For
`ratex', a numbered SOURCE gets `--tagged-value', and every `\\label' is
removed, because RaTeX has no `\\label'.  The overlay keeps SOURCE, so
the label map, built from the source, still sees the labels."
  (let ((source (latex-to-svg-frontend--remove-cookie source)))
    (if (eq engine 'ratex)
        (replace-regexp-in-string
         "\\\\label{[^}]*}" ""
         (if k (latex-to-svg-frontend--tagged-value k source) source)
         t t)
      (if k (latex-to-svg-frontend--setcounter-value k source) source))))

(defun latex-to-svg-frontend--numbered-value (el source table)
  "Return the exact string handed to the backend for EL: SOURCE, numbered.
TABLE is a (OFFSETS . LABELS) scan."
  (let ((k (and (car-safe table)
                (gethash (latex-to-svg-frontend--math-begin el) (car-safe table)))))
    (latex-to-svg-frontend--backend-value
     k source (latex-to-svg-frontend--engine-for source))))

;;;; Rendering

(defun latex-to-svg-frontend--fallback-for (engine)
  "Return the fallback engine for an equation typeset by ENGINE, or nil.
That is `latex' when `latex-to-svg-frontend-fallback' is on and ENGINE is
`ratex'.  `texres' has none: it typesets with LaTeX, so an equation it
rejects has a LaTeX error that `latex' rejects too.  For `skip' or a
warning string (see `--engine-for') nothing is compiled, so there is
none."
  (and latex-to-svg-frontend-fallback
       (eq engine 'ratex)
       'latex))

(defun latex-to-svg-frontend--place (buffer beg end value &optional source enums-fallback display-p engine)
  "Ensure BEG..END in BUFFER shows the current image for render VALUE.
Overlays immediately on a cache hit, else schedules an async compile and
overlays when it finishes.  BEG / END should be markers.  The image is
tinted and sized like the text at BEG (see
`latex-to-svg-frontend--foreground-for' and
`latex-to-svg-frontend--x-height-at').
ENGINE is passed to the backend as `:engine' (nil means `latex'), with
`:fallback' from `--fallback-for' and `:quiet' from
`latex-to-svg-frontend-quiet'.
Any other ENGINE (`skip', or a warning string: see `--engine-for') sends
nothing to the backend and installs `--set-unrendered-overlay' instead.
Nothing is sent either while `latex-to-svg-frontend--graphical-p' is nil.
That, or no graphical window showing BUFFER, sets
`latex-to-svg-frontend--undrawn'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond
       ((not (memq engine '(nil latex ratex texres)))
        (latex-to-svg-frontend--set-unrendered-overlay
         beg end source enums-fallback engine))
       ((not (latex-to-svg-frontend--graphical-p))
        (setq latex-to-svg-frontend--undrawn t))
       (t
        (let* ((fallback (latex-to-svg-frontend--fallback-for engine))
               (frame (latex-to-svg-frontend--display-frame buffer))
               (image (latex-to-svg-backend
                       value
                       :rescale-by (latex-to-svg-frontend--rescale-for display-p)
                       :color (latex-to-svg-frontend--foreground-for beg frame)
                       :background (latex-to-svg-frontend--background-for frame)
                       :padding (latex-to-svg-frontend--padding-for display-p)
                       :x-height (latex-to-svg-frontend--x-height-at
                                     beg buffer)
                       :metadata (car enums-fallback)
                       :engine engine
                       :fallback fallback
                       :quiet latex-to-svg-frontend-quiet
                       :callback (lambda ()
                                   (latex-to-svg-frontend--place
                                    buffer beg end value source enums-fallback display-p
                                    engine)))))
          (unless frame
            (setq latex-to-svg-frontend--undrawn t))
          (when image
            (latex-to-svg-frontend--set-overlay
             beg end value image source enums-fallback display-p engine
             fallback))))))))

(defun latex-to-svg-frontend--render-numbered (el k)
  "Render numbered environment EL starting at counter K."
  (let* ((bounds (latex-to-svg-frontend--element-bounds el))
         (source (latex-to-svg-frontend--math-value el))
         (engine (latex-to-svg-frontend--engine-for source))
         (value (latex-to-svg-frontend--backend-value k source engine))
         (heuristic (latex-to-svg-frontend--count-numbered-equations source)))
    (latex-to-svg-frontend--place (current-buffer)
                                      (copy-marker (car bounds))
                                      (copy-marker (cdr bounds))
                                      value source (cons (1+ k) (+ k heuristic))
                                      (latex-to-svg-frontend--display-p source)
                                      engine)))

(defun latex-to-svg-frontend--render-element (el &optional table)
  "Render math element EL in the current buffer.
TABLE is a (OFFSETS . LABELS) numbering scan; when omitted one is built
on demand.  An `\\eqref' / `\\ref' is drawn as clickable buffer text (its
number, or `(??)' when the label is unknown), a numbered environment via
`--render-numbered'; everything else is typeset verbatim by the backend."
  (let* ((bounds (latex-to-svg-frontend--element-bounds el))
         (source (latex-to-svg-frontend--math-value el))
         (table (or table (latex-to-svg-frontend--maybe-table)))
         (offsets (car-safe table))
         (parsed (and latex-to-svg-frontend-detect-references
                      (eq (latex-to-svg-frontend--math-type el) 'fragment)
                      (latex-to-svg-frontend--reference-parse source)))
         (labels (and parsed (latex-to-svg-frontend--reference-labels
                              (cdr-safe table))))
         (k (and offsets (gethash (latex-to-svg-frontend--math-begin el) offsets))))
    (cond
     ((and parsed labels)
      (let ((num (gethash (cdr parsed) labels)))
        (latex-to-svg-frontend--set-reference-overlay
         (copy-marker (car bounds)) (copy-marker (cdr bounds))
         (cdr parsed) num
         (latex-to-svg-frontend--reference-display-text (car parsed) num))))
     (k (latex-to-svg-frontend--render-numbered el k))
     (t (let ((engine (latex-to-svg-frontend--engine-for source)))
          (latex-to-svg-frontend--place (current-buffer)
                                            (copy-marker (car bounds))
                                            (copy-marker (cdr bounds))
                                            (latex-to-svg-frontend--backend-value
                                             nil source engine)
                                            source nil
                                            (latex-to-svg-frontend--display-p source)
                                            engine))))))

(defun latex-to-svg-frontend--render-region (beg end)
  "Render every math element overlapping BEG..END in the current buffer."
  (let ((table (latex-to-svg-frontend--maybe-table)))
    (dolist (el (latex-to-svg-frontend--elements beg end))
      (latex-to-svg-frontend--render-element el table))))

(defun latex-to-svg-frontend--numbered-overlay-at (pos)
  "Return the numbered-equation overlay covering POS (one with enums), or nil."
  (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-enums))
            (overlays-in pos (min (point-max) (1+ pos)))))

;;;; Incremental (overlay-driven) numbering
;;
;; The numbered overlays already form a document-ordered, marker-anchored
;; structure that records each block's displayed number (`-enums') and raw
;; source (`-source').  After a discrete cursor-leave render, everything above
;; the edited block is already consistent, so we can renumber downward from it
;; \=-- seeding the counter from the preceding overlay and stopping once numbers
;; realign \=-- without scanning buffer text or running the exclusion pass.

(defun latex-to-svg-frontend--numbered-overlays ()
  "This package's numbered overlays (those with enums), ascending by position."
  (sort (seq-filter (lambda (o) (overlay-get o 'latex-to-svg-frontend-enums))
                    (latex-to-svg-frontend--overlays-in (point-min) (point-max)))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun latex-to-svg-frontend--counter-before (pos)
  "Equation counter just before POS, from the nearest preceding numbered overlay.
That overlay's FINAL number is the running counter up to POS; 0 if none."
  (let ((k 0))
    (dolist (ov (latex-to-svg-frontend--numbered-overlays) k)
      (when (< (overlay-start ov) pos)
        (setq k (cdr (overlay-get ov 'latex-to-svg-frontend-enums)))))))

(defun latex-to-svg-frontend--overlay-labels ()
  "Build a label -> number hash from numbered overlays' source and enums.
Mirrors `--scan-numbering' but reads the ordered overlays (ground-truth
numbers) instead of re-scanning buffer text."
  (let ((labels (make-hash-table :test 'equal)))
    (dolist (ov (latex-to-svg-frontend--numbered-overlays))
      (let* ((enums (overlay-get ov 'latex-to-svg-frontend-enums))
             (base (car enums))
             (value (overlay-get ov 'latex-to-svg-frontend-source))
             (env (and value (latex-to-svg-frontend--environment-name value))))
        (when (member env latex-to-svg-frontend--numbered-environments-all)
          (cond
           ((member env latex-to-svg-frontend--numbered-environments-single)
            (when (= (latex-to-svg-frontend--count-numbered-equations value) 1)
              (dolist (name (latex-to-svg-frontend--labels-in value))
                (puthash name base labels))))
           ((member env latex-to-svg-frontend--numbered-environments-multi)
            (dolist (pair (latex-to-svg-frontend--multi-row-labels
                           value env (1- base)))
              (puthash (car pair) (cdr pair) labels)))))))
    labels))

(defun latex-to-svg-frontend--local-table (el)
  "A (OFFSETS . LABELS) table numbering just element EL.
When EL is a numbered environment, OFFSETS maps its begin to
`--counter-before' it (so `--render-element' numbers it without a
whole-buffer scan); otherwise OFFSETS is empty and EL renders verbatim,
matching `--scan-numbering' which only records numbered environments.
LABELS is `--overlay-labels', for an `\\eqref' / `\\ref' being rendered."
  (let ((offsets (make-hash-table :test 'eql))
        (begin (latex-to-svg-frontend--math-begin el)))
    (when (and (eq (latex-to-svg-frontend--math-type el) 'environment)
               (member (latex-to-svg-frontend--environment-name
                        (latex-to-svg-frontend--math-value el))
                       latex-to-svg-frontend--numbered-environments-all))
      (puthash begin (latex-to-svg-frontend--counter-before begin) offsets))
    (cons offsets (latex-to-svg-frontend--overlay-labels))))

(defun latex-to-svg-frontend--renumber-overlay (ov k)
  "Re-render numbered overlay OV at counter K, reusing its stored source.
An unrendered overlay only takes its new number range."
  (let* ((source (overlay-get ov 'latex-to-svg-frontend-source))
         (heuristic (latex-to-svg-frontend--count-numbered-equations source))
         (enums (cons (1+ k) (+ k heuristic))))
    (if (overlay-get ov 'latex-to-svg-frontend-unrendered)
        (overlay-put ov 'latex-to-svg-frontend-enums enums)
      (let ((engine (latex-to-svg-frontend--engine-for source)))
        (latex-to-svg-frontend--place
         (current-buffer)
         (copy-marker (overlay-start ov)) (copy-marker (overlay-end ov))
         (latex-to-svg-frontend--backend-value k source engine)
         source enums (latex-to-svg-frontend--display-p source)
         engine)))))

(defun latex-to-svg-frontend--reconcile-from (pos)
  "Renumber from the just-rendered equation at POS downward, then re-resolve refs.
Assumes overlays before POS are already consistent (true after a discrete
cursor-leave render).  Walks numbered overlays from POS on, seeding the
counter from the preceding overlay, re-rendering each whose number shifted,
and stopping as soon as numbers realign.  Falls back to a full
`--reconcile' on any structural surprise (a downstream overlay with no
usable source).  No-op unless the mode is on; with numbering off, a
`--reconcile' (which then only re-resolves references)."
  (when (bound-and-true-p latex-to-svg-frontend-mode)
    (if (or (not latex-to-svg-frontend-incremental-reconcile)
            (not latex-to-svg-frontend-number-equations))
        (latex-to-svg-frontend--reconcile)
      (setq latex-to-svg-backend-metadata-prefix
            latex-to-svg-frontend--metadata-prefix)
      (let ((k (latex-to-svg-frontend--counter-before pos))
            (fell-back nil))
        (catch 'done
          (dolist (ov (latex-to-svg-frontend--numbered-overlays))
            (when (>= (overlay-start ov) pos)
              (let* ((enums (overlay-get ov 'latex-to-svg-frontend-enums))
                     (source (overlay-get ov 'latex-to-svg-frontend-source))
                     (at-pos (= (overlay-start ov) pos)))
                (unless source
                  (setq fell-back t) (throw 'done nil))
                ;; Past the edited block, an overlay already at its expected
                ;; number means the shift is fully absorbed: stop.
                (when (and (not at-pos) (equal (car enums) (1+ k)))
                  (throw 'done nil))
                ;; The block at POS was just rendered fresh; only renumber the
                ;; ones after it whose base shifted.
                (unless (or at-pos (equal (car enums) (1+ k)))
                  (when (or (overlay-get ov 'display)
                            (overlay-get ov 'latex-to-svg-frontend-unrendered))
                    (latex-to-svg-frontend--renumber-overlay ov k)))
                (setq k (+ k (max 0 (- (cdr enums) (car enums) -1))))))))
        (if fell-back
            (latex-to-svg-frontend--reconcile)
          (latex-to-svg-frontend--reconcile-references
           (latex-to-svg-frontend--overlay-labels)))))))

(defun latex-to-svg-frontend--reconcile-references (labels)
  "Re-resolve every reference preview against LABELS, patching its text.
LABELS is the numbering scan's; `latex-to-svg-frontend-labels-function'
replaces it when set (see `--reference-labels').  Covers all
transitions: a shifted number, a deleted target (number -> `(??)'), and
a target that became defined (`(??)' -> a number).  Uses the
reference's current buffer text for the label, so it also follows a label
edited in place.  Skips a reference revealed for editing (`display' nil)."
  (let ((labels (latex-to-svg-frontend--reference-labels labels)))
    (dolist (ov (latex-to-svg-frontend--overlays-in (point-min) (point-max)))
      (when-let* ((name (overlay-get ov 'latex-to-svg-frontend-ref))
                  (parsed (latex-to-svg-frontend--reference-parse
                           (buffer-substring-no-properties
                            (overlay-start ov) (overlay-end ov)))))
        (let ((want (gethash (cdr parsed) labels)))
          (unless (equal want (overlay-get ov 'latex-to-svg-frontend-ref-num))
            (let ((disp (latex-to-svg-frontend--reference-display-text
                         (car parsed) want)))
              (overlay-put ov 'latex-to-svg-frontend-ref-display disp)
              (when (overlay-get ov 'display)
                (overlay-put ov 'display disp))
              (overlay-put ov 'latex-to-svg-frontend-ref-num want))))))))

(defvar-local latex-to-svg-frontend--reconcile-timer nil
  "Pending debounced reconcile timer for this buffer.")

(defvar-local latex-to-svg-frontend--initial-render-timer nil
  "Timer of the render that turning the mode on schedules, or nil.
See `latex-to-svg-frontend--render-when-on'.")

(defvar-local latex-to-svg-frontend--dirty nil
  "Cons (BEG . END) bounding buffer text changed since the last full reconcile.
Accumulated from `after-change-functions'; nil when nothing is pending.  A
clean cursor-leave cancels the pending debounced pass only when this range
lies wholly inside the equation it just reconciled (`--maybe-cancel-reconcile').")

(defun latex-to-svg-frontend--mark-dirty (beg end)
  "Grow the pending-change range to cover BEG..END."
  (setq latex-to-svg-frontend--dirty
        (if latex-to-svg-frontend--dirty
            (cons (min beg (car latex-to-svg-frontend--dirty))
                  (max end (cdr latex-to-svg-frontend--dirty)))
          (cons beg end))))

(defun latex-to-svg-frontend--cancel-reconcile ()
  "Cancel any pending debounced reconcile and clear the pending-change range."
  (when (timerp latex-to-svg-frontend--reconcile-timer)
    (cancel-timer latex-to-svg-frontend--reconcile-timer))
  (setq latex-to-svg-frontend--reconcile-timer nil
        latex-to-svg-frontend--dirty nil))

(defun latex-to-svg-frontend--maybe-cancel-reconcile (beg end)
  "Cancel the pending debounced pass if all pending changes are within BEG..END.
Called after a clean cursor-leave has reconciled the equation spanning
BEG..END: if nothing changed outside it, the whole-buffer catch-up pass is
moot.  When changes also happened elsewhere (e.g. a paste), the range is
wider and the pass is kept -- the incremental leave cannot see undrawn
equations, so the full scan is still needed."
  (when (and latex-to-svg-frontend--dirty
             (>= (car latex-to-svg-frontend--dirty) beg)
             (<= (cdr latex-to-svg-frontend--dirty) end))
    (latex-to-svg-frontend--cancel-reconcile)))

(defun latex-to-svg-frontend--reconcile (&optional buffer)
  "Recompute equation numbers and re-render previews whose number changed.
Operate in BUFFER (default the current buffer).
A comprehensive pass: also cancels any pending debounced reconcile and clears
the pending-change range.  No-op unless the mode is on.  With numbering
off, only re-resolves the references, and only when
`latex-to-svg-frontend-labels-function' is set."
  (with-current-buffer (or buffer (current-buffer))
    (when (and (bound-and-true-p latex-to-svg-frontend-mode)
               (not latex-to-svg-frontend-number-equations)
               latex-to-svg-frontend-labels-function)
      (latex-to-svg-frontend--reconcile-references nil)
      (latex-to-svg-frontend--cancel-reconcile))
    (when (and (bound-and-true-p latex-to-svg-frontend-mode)
               latex-to-svg-frontend-number-equations)
      (setq latex-to-svg-backend-metadata-prefix latex-to-svg-frontend--metadata-prefix)
      ;; One environment scan feeds both the counter threading below and the
      ;; reference re-resolution (via `--scan-numbering'), instead of scanning
      ;; the whole buffer twice per reconcile.
      (let ((envs (latex-to-svg-frontend--environments))
            (k 0))
        (dolist (el envs)
          (let ((env (latex-to-svg-frontend--environment-name
                      (latex-to-svg-frontend--math-value el))))
            (when (member env latex-to-svg-frontend--numbered-environments-all)
              (let* ((begin (latex-to-svg-frontend--math-begin el))
                     (ov (latex-to-svg-frontend--numbered-overlay-at begin))
                     (enums (and ov (overlay-get ov 'latex-to-svg-frontend-enums)))
                     (consumed (if enums
                                   (- (cdr enums) (car enums) -1)
                                 (latex-to-svg-frontend--count-numbered-equations
                                  (latex-to-svg-frontend--math-value el)))))
                (when (and ov (not (equal (car enums) (1+ k))))
                  (cond
                   ((overlay-get ov 'latex-to-svg-frontend-unrendered)
                    (latex-to-svg-frontend--renumber-overlay ov k))
                   ((overlay-get ov 'display)
                    (latex-to-svg-frontend--render-numbered el k))))
                (setq k (+ k (max 0 consumed)))))))
        (latex-to-svg-frontend--reconcile-references
         (cdr (latex-to-svg-frontend--scan-numbering envs))))
      (latex-to-svg-frontend--cancel-reconcile))))

(defun latex-to-svg-frontend--schedule-reconcile (&optional beg end _len)
  "Debounce a numbering reconcile of the current buffer (see `--reconcile').
Hooked to `after-change-functions' (which passes BEG END _LEN) and also
fired with no arguments when ground truth corrects a heuristic guess.  A
backstop, run by `--debounced-pass': it re-renders any preview edited
and left (`--heal-modified'), renders math that arrived with no preview
\(a paste, a yank, an undo: `--render-undrawn'), and renumbers
downstream; the initial render of newly typed math is handled
event-driven, on cursor leave (`--render-on-leave'), not here.  Records the
changed range so a clean leave can cancel this pass when it covered
everything (`--maybe-cancel-reconcile').  No-op unless the mode and the idle
option are on."
  (when (and (bound-and-true-p latex-to-svg-frontend-mode)
             latex-to-svg-frontend-reconcile-idle)
    ;; A region-less call (ground-truth correction) marks the whole buffer
    ;; dirty, so a single-equation leave never cancels it.
    (if (and beg end)
        (latex-to-svg-frontend--mark-dirty beg end)
      (latex-to-svg-frontend--mark-dirty (point-min) (point-max)))
    (when (timerp latex-to-svg-frontend--reconcile-timer)
      (cancel-timer latex-to-svg-frontend--reconcile-timer))
    (let ((buf (current-buffer)))
      (setq latex-to-svg-frontend--reconcile-timer
            (run-with-idle-timer
             latex-to-svg-frontend-reconcile-idle nil
             #'latex-to-svg-frontend--debounced-pass buf)))))

(defun latex-to-svg-frontend--debounced-pass (buffer)
  "Run the debounced pass `--schedule-reconcile' armed for BUFFER.
Re-render previews edited and left, render the math in the changed range
that has no preview, then reconcile numbers and references."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq latex-to-svg-frontend--reconcile-timer nil)
      ;; `--reconcile' clears the range, so take it first.
      (let ((dirty latex-to-svg-frontend--dirty))
        (when (bound-and-true-p latex-to-svg-frontend-mode)
          (latex-to-svg-frontend--heal-modified)
          (when dirty
            (latex-to-svg-frontend--render-undrawn (car dirty) (cdr dirty)))))
      (latex-to-svg-frontend--reconcile buffer))))

(defun latex-to-svg-frontend--render-undrawn (beg end)
  "Render the math overlapping BEG..END that has no preview.
Math pasted, yanked or restored by an undo arrives with no preview, and
`--render-on-leave' renders only math that point entered and left.  The
equation containing point is skipped, as `--render-on-leave' skips it,
so math still being typed is never compiled."
  (let ((beg (max (point-min) beg))
        (end (min (point-max) end))
        (table nil))
    (when (< beg end)
      (dolist (el (latex-to-svg-frontend--elements beg end))
        (let ((b (latex-to-svg-frontend--math-begin el))
              (e (latex-to-svg-frontend--math-end el)))
          (unless (or (<= b (point) e)
                      (latex-to-svg-frontend--overlays-in b e))
            (latex-to-svg-frontend--render-element
             el (or table (setq table (latex-to-svg-frontend--maybe-table))))))))))

;;;; Refresh (theme / font tracking)

(defun latex-to-svg-frontend--refresh-overlay (ov)
  "Fetch preview overlay OV's image again.
Uses the value, engine and fallback recorded on OV, and tints and sizes
it like the text at its start now (see
`latex-to-svg-frontend--foreground-for' and
`latex-to-svg-frontend--x-height-at').
When the cache has no picture for them, because a backend option in the
cache key changed \(`latex-to-svg-backend-preamble',
`latex-to-svg-backend-preamble-not-precompiled') or the entry was
collected, the backend compiles it and this runs again when the compile
is done.  OV keeps its old image until then; an OV
deleted in the meantime (edited, renumbered) is left alone.  Nothing is
fetched while `latex-to-svg-frontend--graphical-p' is nil."
  (when-let* ((buffer (overlay-buffer ov))
              (value (overlay-get ov 'latex-to-svg-frontend-value)))
    (with-current-buffer buffer
      (when (latex-to-svg-frontend--graphical-p)
        (let ((frame (latex-to-svg-frontend--display-frame buffer)))
          (when-let* ((image (latex-to-svg-backend
                              value
                              :rescale-by (latex-to-svg-frontend--rescale-for
                                           (overlay-get ov 'latex-to-svg-frontend-display-math))
                              :color (latex-to-svg-frontend--foreground-for
                                      (overlay-start ov) frame)
                              :background (latex-to-svg-frontend--background-for frame)
                              :padding (latex-to-svg-frontend--padding-for
                                        (overlay-get ov 'latex-to-svg-frontend-display-math))
                              :x-height (latex-to-svg-frontend--x-height-at
                                            (overlay-start ov) buffer)
                              :metadata (car (overlay-get
                                              ov 'latex-to-svg-frontend-enums))
                              :engine (overlay-get
                                       ov 'latex-to-svg-frontend-engine)
                              :fallback (overlay-get
                                         ov 'latex-to-svg-frontend-fallback)
                              :quiet latex-to-svg-frontend-quiet
                              :callback
                              (lambda ()
                                (when (overlay-buffer ov)
                                  (latex-to-svg-frontend--refresh-overlay ov))))))
            (overlay-put ov 'latex-to-svg-frontend-image image)
            (when (overlay-get ov 'display)
              (latex-to-svg-frontend--show-image ov image))))))))

(defun latex-to-svg-frontend--refresh-buffer (buffer)
  "Fetch BUFFER's previews again for the current appearance.
Each preview is fetched by `--refresh-overlay': from the cache, re-tinted
and re-scaled, or compiled when the cache has no picture for it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((appearance (latex-to-svg-frontend--appearance)))
        (dolist (ov (latex-to-svg-frontend--overlays-in (point-min) (point-max)))
          (latex-to-svg-frontend--refresh-overlay ov))
        (setq latex-to-svg-frontend--rendered-appearance appearance)))))

;;;###autoload
(defun latex-to-svg-frontend-refresh (&optional buffer recompile)
  "Bring the previews in BUFFER (default current) up to date.
An equation with no preview is rendered, except the one containing
point; one whose engine or fallback no longer matches the options
\(`latex-to-svg-frontend-engine', `latex-to-svg-frontend-fallback') is
rendered again; every other preview is redrawn from the cache for the
current theme, font, colors and size, or compiled again when the cache
has no picture for it, as after a change of
`latex-to-svg-backend-line-width'.  Numbers and references are then
reconciled.  The options in `latex-to-svg-frontend--watched-options' do
this on their own when set; run it after a change they cannot see, such
as another backend option (`latex-to-svg-backend-font-scale').

With RECOMPILE non-nil (interactively, a prefix argument), recompile
the previews in BUFFER instead, bypassing the cache: the way to retry
after a fix the cache cannot see, such as installing a missing TeX
package or upgrading RaTeX.  Either way only BUFFER is touched."
  (interactive (list nil current-prefix-arg))
  (with-current-buffer (or buffer (current-buffer))
    (if recompile
        (progn
          (latex-to-svg-frontend--regenerate (point-min) (point-max))
          (latex-to-svg-frontend--reconcile))
      (latex-to-svg-frontend--update-buffer (current-buffer)))))

(define-obsolete-function-alias 'latex-to-svg-frontend
  #'latex-to-svg-frontend-refresh "0.17.0"
  "The mode renders the math, and `latex-to-svg-frontend-refresh' brings
it up to date after an option changes.")

(defun latex-to-svg-frontend--needs-render-p (el)
  "Non-nil when math element EL has to be rendered to be up to date.
That is when it has no preview, or a preview made for another engine or
fallback than the options now give it (see `--engine-for' and
`--fallback-for').  The element containing point is never rendered, as
`--render-on-leave' never renders it."
  (let ((b (latex-to-svg-frontend--math-begin el))
        (e (latex-to-svg-frontend--math-end el)))
    (unless (<= b (point) e)
      (let ((ovs (latex-to-svg-frontend--overlays-in b e)))
        (if (null ovs)
            t
          (when-let* ((ov (seq-find
                           (lambda (o)
                             (or (overlay-get o 'latex-to-svg-frontend-value)
                                 (overlay-get o 'latex-to-svg-frontend-unrendered)))
                           ovs)))
            (let ((engine (latex-to-svg-frontend--engine-for
                           (latex-to-svg-frontend--math-value el))))
              (or (not (equal engine
                              (overlay-get ov 'latex-to-svg-frontend-engine)))
                  (not (eq (latex-to-svg-frontend--fallback-for engine)
                           (overlay-get ov 'latex-to-svg-frontend-fallback)))))))))))

(defun latex-to-svg-frontend--update-buffer (buffer)
  "Bring BUFFER's previews up to date; see `latex-to-svg-frontend-refresh'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((table nil))
        (dolist (el (latex-to-svg-frontend--elements (point-min) (point-max)))
          (when (latex-to-svg-frontend--needs-render-p el)
            (latex-to-svg-frontend--render-element
             el (or table (setq table (latex-to-svg-frontend--maybe-table)))))))
      (latex-to-svg-frontend--refresh-buffer buffer)
      (latex-to-svg-frontend--reconcile buffer))))

;;;; Updating after an option changes

(defconst latex-to-svg-frontend--watched-options
  '(latex-to-svg-frontend-engine
    latex-to-svg-frontend-fallback
    latex-to-svg-frontend-foreground-color
    latex-to-svg-frontend-background-color
    latex-to-svg-frontend-padding
    latex-to-svg-frontend-padding-inline
    latex-to-svg-frontend-padding-display
    latex-to-svg-frontend-rescale-inline
    latex-to-svg-frontend-rescale-display
    latex-to-svg-frontend-center-display-math
    latex-to-svg-backend-preamble
    latex-to-svg-backend-appended-preamble
    latex-to-svg-backend-preamble-not-precompiled
    latex-to-svg-backend-line-width
    latex-to-svg-backend-ratex-macros)
  "Options whose change updates the previews on its own.
Each has a variable watcher (`latex-to-svg-frontend--option-changed').
The last five are the backend's options in the cache key that a project
sets in `.dir-locals.el': its three preambles, the width of numbered
equations and RaTeX's macros.")

(defvar latex-to-svg-frontend--option-timer nil
  "Timer of the pending update after an option changed, or nil.")

(defvar latex-to-svg-frontend--option-buffers nil
  "Buffers whose local value of a watched option changed, to update.")

(defvar latex-to-svg-frontend--option-defaults nil
  "Watched options whose default value changed, to update the buffers using it.")

(defun latex-to-svg-frontend--option-changed (symbol _newval operation where)
  "Schedule the update after SYMBOL, one of `--watched-options', changed.
A variable watcher: OPERATION is how it changed and WHERE the buffer
whose local value changed, or nil for the default value.  A change of
the default value (`setq' of a global value, `setq-default', Customize)
updates every buffer with previews that has no local value of SYMBOL; a
buffer-local one (`setq-local', `.dir-locals.el') updates that buffer.
A let-binding updates nothing.  The watcher runs before the value is
set, so the update runs from a timer, which also takes several changes
in one go (a block of `setq's in an init file)."
  (when (eq operation 'set)
    (if where
        (setq latex-to-svg-frontend--option-buffers
              (cl-adjoin where latex-to-svg-frontend--option-buffers))
      (setq latex-to-svg-frontend--option-defaults
            (cl-adjoin symbol latex-to-svg-frontend--option-defaults)))
    (unless (timerp latex-to-svg-frontend--option-timer)
      (setq latex-to-svg-frontend--option-timer
            (run-at-time 0 nil #'latex-to-svg-frontend--update-after-option)))))

(defun latex-to-svg-frontend--update-after-option ()
  "Update the buffers `--option-changed' collected (see `--update-buffer').
That is each buffer with previews whose local value of a watched option
changed, or that has no local value of an option whose default changed."
  (let ((buffers latex-to-svg-frontend--option-buffers)
        (defaults latex-to-svg-frontend--option-defaults))
    (setq latex-to-svg-frontend--option-buffers nil
          latex-to-svg-frontend--option-defaults nil
          latex-to-svg-frontend--option-timer nil)
    (dolist (buf (if defaults (buffer-list) buffers))
      (when (and (buffer-live-p buf)
                 (buffer-local-value 'latex-to-svg-frontend-mode buf)
                 (or (memq buf buffers)
                     (seq-some (lambda (option)
                                 (not (local-variable-p option buf)))
                               defaults)))
        (latex-to-svg-frontend--update-buffer buf)))))

(dolist (option latex-to-svg-frontend--watched-options)
  (add-variable-watcher option #'latex-to-svg-frontend--option-changed))

(defun latex-to-svg-frontend--present-p ()
  "Return non-nil if the current buffer has preview overlays."
  (and latex-to-svg-frontend-mode
       (latex-to-svg-frontend--overlays-in (point-min) (point-max))))

(defun latex-to-svg-frontend--refresh-if-changed ()
  "Bring the current buffer's previews up to date with how it is shown.
When `latex-to-svg-frontend--undrawn' is set and a graphical window
shows the buffer, render the math with no preview (see
`--update-buffer'): math skipped while no frame was graphical, or
requested while no window showed the buffer.  Otherwise refresh the
previews if the appearance changed.  Nothing can be drawn without a
graphical window, so neither runs while none shows the buffer; the
check runs again when one does."
  (cond ((and latex-to-svg-frontend-mode
              latex-to-svg-frontend--undrawn
              (latex-to-svg-frontend--display-window (current-buffer)))
         (setq latex-to-svg-frontend--undrawn nil)
         (latex-to-svg-frontend--update-buffer (current-buffer)))
        ((and (latex-to-svg-frontend--present-p)
              (latex-to-svg-frontend--display-window (current-buffer))
              (not (equal (latex-to-svg-frontend--appearance)
                          latex-to-svg-frontend--rendered-appearance)))
         (latex-to-svg-frontend--refresh-buffer (current-buffer)))))

(defun latex-to-svg-frontend--maybe-refresh (&rest _)
  "Schedule a lazy appearance-changed refresh of the current buffer."
  (when latex-to-svg-frontend-mode
    (let ((buf (current-buffer)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (latex-to-svg-frontend--refresh-if-changed))))))))

;;;###autoload
(defun latex-to-svg-frontend-on-appearance-change (&rest _)
  "Refresh every preview buffer whose appearance changed.

The mode tracks per-buffer changes itself (redisplay and buffer-local
zoom), but a theme switch and a *frame* font change are global events
with no per-buffer hook, so the package installs nothing on your behalf.
For previews to follow them immediately, add this one function to both
global hooks, mirroring how the mode itself is enabled:

  (add-hook \\='enable-theme-functions
            #\\='latex-to-svg-frontend-on-appearance-change)
  (add-hook \\='after-setting-font-hook
            #\\='latex-to-svg-frontend-on-appearance-change)

The second covers `set-frame-font', `doom/increase-font-size' and
`doom-big-font-mode'.  Both are optional: previews otherwise re-tint and
rescale on their next redisplay.

Each buffer is appearance-checked individually (colors + measured font
height), so buffers on a frame the change did not touch cost nothing,
and nothing is recompiled \=-- previews are re-fetched from the cache."
  (run-at-time
   0 nil
   (lambda ()
     (dolist (buf (buffer-list))
       (when (buffer-local-value 'latex-to-svg-frontend-mode buf)
         (with-current-buffer buf
           (latex-to-svg-frontend--refresh-if-changed)))))))

;;;###autoload
(define-obsolete-function-alias 'latex-to-svg-frontend-on-theme-change
  #'latex-to-svg-frontend-on-appearance-change "0.14.0")

;;;; Command and mode

(defun latex-to-svg-frontend--ref-overlay-at (pos)
  "Return this package's reference overlay covering POS, or nil."
  (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
            (overlays-in (max (point-min) (1- pos))
                         (min (point-max) (1+ pos)))))

(defun latex-to-svg-frontend-goto-reference (&optional event)
  "Jump to the equation defining the label of the reference preview at point.
EVENT is the triggering input event.  When no equation in the buffer
defines the label, `latex-to-svg-frontend-find-label-function', if set,
is given the label, with point on the reference.
Bound in `\\eqref' / `\\ref' preview overlays to `mouse-2' and
\\<latex-to-svg-frontend--reference-keymap>\\[latex-to-svg-frontend-goto-reference]
\(and to RET when `latex-to-svg-frontend-return-follows-reference' is
on); a short `mouse-1' click gets here too, translated to `mouse-2' by
Emacs' `follow-link' mechanism (see `mouse-1-click-follows-link')."
  (interactive (list last-command-event))
  (when (and (consp event) (eventp event))
    (let ((posn (event-start event)))
      (when (windowp (posn-window posn)) (select-window (posn-window posn)))
      (when (numberp (posn-point posn)) (goto-char (posn-point posn)))))
  (let* ((ov (latex-to-svg-frontend--ref-overlay-at (point)))
         (label (and ov (overlay-get ov 'latex-to-svg-frontend-ref)))
         (pos (and label (latex-to-svg-frontend--label-position label))))
    (cond
     ((null label) (user-error "No equation reference here"))
     ((and (null pos) latex-to-svg-frontend-find-label-function
           (funcall latex-to-svg-frontend-find-label-function label)))
     ((null pos) (user-error "Cannot find an equation labelled %s" label))
     (t (push-mark)
        (goto-char pos)
        (when latex-to-svg-frontend-reveal-function
          (funcall latex-to-svg-frontend-reveal-function))
        (when (get-buffer-window (current-buffer)) (recenter))
        (message "Jumped to \\label{%s}" label)))))

(defvar latex-to-svg-frontend--reference-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] #'latex-to-svg-frontend-goto-reference)
    ;; Declare the span a link, so Emacs' generic mouse-1 translation applies:
    ;; a short mouse-1 click (see `mouse-1-click-follows-link') is rewritten to
    ;; mouse-2 and jumps, while a long click falls through to `mouse-set-point'
    ;; and reveals the source, and a drag still selects.  Same idiom as Org's
    ;; `org-mouse-map'; the `mouse-face' value pairs with the `mouse-face'
    ;; property set in `latex-to-svg-frontend--set-reference-overlay'.
    (define-key map [follow-link] 'mouse-face)
    ;; `C-c C-o' is the keyboard gesture, as in Org (`org-open-at-point').
    (define-key map (kbd "C-c C-o") #'latex-to-svg-frontend-goto-reference)
    ;; RET only when opted in; a `:filter' keeps the defcustom live-toggleable.
    (define-key map (kbd "RET")
                `(menu-item "" latex-to-svg-frontend-goto-reference
                            :filter ,(lambda (cmd)
                                       (and latex-to-svg-frontend-return-follows-reference
                                            cmd))))
    map)
  "Keymap installed on `\\eqref' / `\\ref' preview overlays for click-to-jump.")

;;;###autoload
(defun latex-to-svg-frontend-clear (&optional beg end)
  "Clear previews in BEG..END, revealing the LaTeX source.
Interactively acts on the active region, or the whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (point-min) (point-max))))
  (latex-to-svg-frontend--clear-region (or beg (point-min)) (or end (point-max))))

(defun latex-to-svg-frontend--regenerate (beg end)
  "Recompile the previews in BEG..END, bypassing the cache.
Deletes each equation's cached SVG (via `latex-to-svg-backend-invalidate')
and clears its overlay, then re-renders.  With a fallback engine (see
`latex-to-svg-frontend-fallback'), the fallback's SVG is deleted too, and
so is the record of the engine's failure, so the engine is tried again.
When an equation is typeset with LaTeX or texres, as the engine or the
fallback, the buffer's `.fmt' files are deleted too
\(`latex-to-svg-backend-invalidate-format', one per TeX program): each
holds the files the preamble loads as they were when it was dumped, so
an edit to one, such as the `macros.tex' of an `\\input{macros.tex}',
would not reach the recompiled equations.  The next compile dumps them
again.
Run by `latex-to-svg-frontend-refresh' with a prefix argument."
  (let ((table (latex-to-svg-frontend--maybe-table))
        (latex nil))
    (dolist (el (latex-to-svg-frontend--elements beg end))
      (let* ((source (latex-to-svg-frontend--math-value el))
             (engine (latex-to-svg-frontend--engine-for source)))
        (when (memq engine '(latex ratex texres))
          (let ((value (latex-to-svg-frontend--numbered-value el source table))
                (fallback (latex-to-svg-frontend--fallback-for engine)))
            (when (or (memq engine '(latex texres)) (eq fallback 'latex))
              (setq latex t))
            (latex-to-svg-backend-invalidate value engine)
            (when fallback
              (latex-to-svg-backend-invalidate value fallback))))))
    (when latex
      (latex-to-svg-backend-invalidate-format))
    (latex-to-svg-frontend--clear-region beg end)
    (latex-to-svg-frontend--render-region beg end)))

(defun latex-to-svg-frontend-regenerate (&optional beg end)
  "Recompile the previews in BEG..END, bypassing the cache.
Interactively acts on the active region, or the whole buffer.  Obsolete:
run `latex-to-svg-frontend-refresh' with a prefix argument, which does
this for the whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (point-min) (point-max))))
  (latex-to-svg-frontend--regenerate (or beg (point-min)) (or end (point-max))))
(make-obsolete 'latex-to-svg-frontend-regenerate
               "run `latex-to-svg-frontend-refresh' with a prefix argument."
               "0.17.0")

(defvar latex-to-svg-frontend-mode-map (make-sparse-keymap)
  "Keymap for `latex-to-svg-frontend-mode'.
Empty: the mode binds no key, so it shadows no command of the markup's
own mode, such as `markdown-toggle-url-hiding'.")

;;;###autoload
;;;; Emphasis suppression (font-lock)

(defun latex-to-svg-frontend--pos-in-span-p (pos spans)
  "Non-nil when POS is strictly inside one of SPANS (each a (BEG . END) cons).
Strict (BEG < POS < END) so a marker *inside* math matches while the span's
own delimiters do not."
  (seq-some (lambda (s) (and (< (car s) pos) (< pos (cdr s)))) spans))

(defun latex-to-svg-frontend--suppress-emphasis (limit)
  "Font-lock keyword: neutralize markup emphasis decoration over math.
Runs after the markup's own emphasis fontifier (added with `append').

Markup font-lock has no LaTeX awareness, so a stray marker *inside* an
equation (the `=' in `\\(\\Delta{=}0\\)', the `+' in `(+)', ...) gets read as
an emphasis/verbatim delimiter.  It may pair with its partner inside the same
equation, or with one inside the *next* equation -- and org then paints the
whole run, including any prose caught in between (a real annoyance stock Org
preview has no defense against).

Such a face is entirely spurious (the markers are LaTeX syntax, not prose
markup), so rather than blanket-covering each math span we walk the `face'
runs in POINT..LIMIT and, for any run whose first or last character falls
strictly inside a detected math span (i.e. a run anchored to a marker that
lives in math), *remove* the `face' over the whole run.  Removing rather than
masking clears the run's colour too, so bridged prose (`org-verbatim' tint and
all) is fully restored, not merely un-struck.  A legitimate prose emphasis that
merely *contains* inline math (its markers in prose, endpoints outside every
span) is left untouched.  Returns nil (own fontification, one call per chunk).

\(The masking `latex-to-svg-frontend--neutralize-face' is still used on preview
overlays, where an image covers the text and only drawn-over decoration --
not colour -- matters.)"
  (when latex-to-svg-frontend-suppress-emphasis
    (let ((spans (mapcar (lambda (el)
                           (cons (latex-to-svg-frontend--math-begin el)
                                 (latex-to-svg-frontend--math-end el)))
                         (latex-to-svg-frontend--scan (point) limit))))
      (when spans
        (let ((p (point)))
          (while (< p limit)
            (let ((q (or (next-single-property-change p 'face nil limit)
                         limit)))
              (when (and (get-text-property p 'face)
                         (or (latex-to-svg-frontend--pos-in-span-p p spans)
                             (latex-to-svg-frontend--pos-in-span-p (1- q) spans)))
                (remove-text-properties p q '(face nil)))
              (setq p q)))))))
  (goto-char limit)
  nil)

(defconst latex-to-svg-frontend--font-lock-keywords
  '((latex-to-svg-frontend--suppress-emphasis))
  "Font-lock keywords added while the mode is on (appended, so they run last).
They are added only in a buffer whose major mode sets `font-lock-defaults'
\(see `latex-to-svg-frontend--add-font-lock-keywords').")

(defvar-local latex-to-svg-frontend--font-lock-added nil
  "Non-nil when the mode added `latex-to-svg-frontend--font-lock-keywords'.")

(defun latex-to-svg-frontend--add-font-lock-keywords ()
  "Add `latex-to-svg-frontend--font-lock-keywords', if the buffer needs them.
They undo the faces a markup's font-lock puts on math, so they are added
only when the major mode sets `font-lock-defaults'.  In a buffer without
font-lock keywords, such as a Gnus article, `font-lock-mode' does
nothing; a keyword would make it fontify, and fontifying first removes
every `face' property, including the faces the major mode put on the
text itself."
  (when font-lock-defaults
    (font-lock-add-keywords
     nil latex-to-svg-frontend--font-lock-keywords 'append)
    (setq latex-to-svg-frontend--font-lock-added t)
    (when font-lock-mode (font-lock-flush))))

(defun latex-to-svg-frontend--remove-font-lock-keywords ()
  "Remove the keywords `--add-font-lock-keywords' added, if it added them."
  (when latex-to-svg-frontend--font-lock-added
    (font-lock-remove-keywords
     nil latex-to-svg-frontend--font-lock-keywords)
    (setq latex-to-svg-frontend--font-lock-added nil)
    (when font-lock-mode (font-lock-flush))))

(defun latex-to-svg-frontend--render-when-on (buffer)
  "Render all math in BUFFER, if `latex-to-svg-frontend-mode' is still on.
Run from the timer that turning the mode on schedules in a buffer
visiting a file (see `latex-to-svg-frontend-mode')."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq latex-to-svg-frontend--initial-render-timer nil)
      (when latex-to-svg-frontend-mode
        (latex-to-svg-frontend--render-region (point-min) (point-max))))))

(defun latex-to-svg-frontend--before-major-mode-change ()
  "Turn `latex-to-svg-frontend-mode' off before the major mode changes.
Run from `change-major-mode-hook', as by `normal-mode' or `revert-buffer'.
The change resets the buffer's local variables, which turns the mode off
without running its body, but keeps its overlays: previews compiled with
the old options would stay, and one whose equation no longer compiles
would stay for good.  Turning the mode off clears them; the new major
mode's hook, from which the mode is usually turned on, renders again."
  (latex-to-svg-frontend-mode -1))

(define-minor-mode latex-to-svg-frontend-mode
  "Minor mode previewing LaTeX math as SVG images via `latex-to-svg-backend'.

This is the shared core; normally you enable it through a per-markup
adaptor mode (e.g. `latex-to-svg-for-markdown-mode') that first installs
the buffer-local protocol (`latex-to-svg-frontend-exclude-function' etc.).
When enabled, all detected math is rendered, and math typed, pasted or
edited later is rendered as it arrives; disabling clears it.  In a
buffer visiting a file, the first render runs from a timer, after the
file's local variables are applied: Emacs runs a major mode's hooks,
where the mode is usually turned on, before it applies them, and they
may set an option the render needs, such as
`latex-to-svg-backend-preamble-not-precompiled' in `.dir-locals.el'.  Setting
an option of this package updates the previews on its own (see
`latex-to-svg-frontend--watched-options')."
  :lighter " L2S"
  :keymap latex-to-svg-frontend-mode-map
  (if latex-to-svg-frontend-mode
      (progn
        (add-hook 'window-buffer-change-functions
                  #'latex-to-svg-frontend--maybe-refresh nil t)
        (add-hook 'text-scale-mode-hook
                  #'latex-to-svg-frontend--maybe-refresh nil t)
        (add-hook 'after-change-functions
                  #'latex-to-svg-frontend--schedule-reconcile nil t)
        (add-hook 'post-command-hook
                  #'latex-to-svg-frontend--handle-cursor nil t)
        (add-hook 'change-major-mode-hook
                  #'latex-to-svg-frontend--before-major-mode-change nil t)
        (latex-to-svg-frontend--add-font-lock-keywords)
        (if buffer-file-name
            (unless (timerp latex-to-svg-frontend--initial-render-timer)
              (setq latex-to-svg-frontend--initial-render-timer
                    (run-at-time 0 nil #'latex-to-svg-frontend--render-when-on
                                 (current-buffer))))
          (latex-to-svg-frontend--render-region (point-min) (point-max))))
    (remove-hook 'window-buffer-change-functions
                 #'latex-to-svg-frontend--maybe-refresh t)
    (remove-hook 'text-scale-mode-hook
                 #'latex-to-svg-frontend--maybe-refresh t)
    (remove-hook 'after-change-functions
                 #'latex-to-svg-frontend--schedule-reconcile t)
    (remove-hook 'post-command-hook #'latex-to-svg-frontend--handle-cursor t)
    (remove-hook 'change-major-mode-hook
                 #'latex-to-svg-frontend--before-major-mode-change t)
    (latex-to-svg-frontend--remove-font-lock-keywords)
    (when (markerp latex-to-svg-frontend--last-point)
      (set-marker latex-to-svg-frontend--last-point nil))
    (setq latex-to-svg-frontend--last-point nil)
    (when (timerp latex-to-svg-frontend--reconcile-timer)
      (cancel-timer latex-to-svg-frontend--reconcile-timer)
      (setq latex-to-svg-frontend--reconcile-timer nil))
    (when (timerp latex-to-svg-frontend--initial-render-timer)
      (cancel-timer latex-to-svg-frontend--initial-render-timer)
      (setq latex-to-svg-frontend--initial-render-timer nil))
    (latex-to-svg-frontend--clear-region (point-min) (point-max))
    (setq latex-to-svg-frontend--rendered-appearance nil
          latex-to-svg-frontend--undrawn nil)))

(provide 'latex-to-svg-frontend)

;;; latex-to-svg-frontend.el ends here
