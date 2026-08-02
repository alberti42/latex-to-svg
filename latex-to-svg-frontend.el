;;; latex-to-svg-frontend.el --- Preview LaTeX math in markup buffers as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.9.0
;; Package-Requires: ((emacs "29.1") (latex-to-svg-backend "0.4.0"))
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
;; The shared front-end core over the `latex-to-svg-backend' rendering engine.
;; It detects LaTeX math in a markup buffer, overlays each occurrence with an
;; SVG typeset by the engine, and provides equation numbering, `\\eqref' /
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
;; Because the engine renders its input *verbatim*, the core passes each
;; element's source (delimiters and all).  The engine compiles each unique
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
;; clean leave (delete, paste, undo).

;;; Code:

(require 'latex-to-svg-backend)
(require 'seq)
(require 'cl-lib)

(defgroup latex-to-svg-frontend nil
  "Preview LaTeX math in markup buffers as SVG via `latex-to-svg-backend'."
  :group 'text
  :prefix "latex-to-svg-frontend-")

(defcustom latex-to-svg-frontend-number-equations t
  "Whether to compute and bake equation numbers into display-math previews.

When non-nil, numbered LaTeX environments (`equation', `align', …) are
rendered with a `\\setcounter{equation}{N}' prefix so each preview shows
its real document-wide number.  N is derived purely in Elisp by counting
the numbered equations that precede the block (see docs/numbering.md); the
number is part of the engine's content hash, so a block re-renders only
when its number actually changes.

When nil, every element renders verbatim (no numbering)."
  :type 'boolean
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-reconcile-idle 0.4
  "Idle seconds before equation numbers are reconciled after an edit.
When numbering is on, editing schedules a debounced pass that re-renders
any downstream preview whose number changed (see
`latex-to-svg-frontend--reconcile').  nil disables the automatic pass
\(numbers then refresh only on an explicit render)."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-incremental-reconcile t
  "When non-nil, renumber incrementally on a cursor-leave render.
Leaving a just-typed or edited equation renumbers only from that equation
downward, seeding the counter from the nearest preceding overlay and
stopping as soon as numbers realign \=-- no whole-buffer scan (see
`latex-to-svg-frontend--reconcile-from').  The equation's own number is
likewise computed from that preceding overlay rather than by a full scan.
Falls back to a full `latex-to-svg-frontend--reconcile' on any structural
surprise, and the debounced backstop / explicit commands always use the
full pass.  Set to nil to force the full scan everywhere."
  :type 'boolean
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-inline-rescale 1.0
  "Size multiplier for inline math previews (`$…$', `\\(…\\)').
Applied on top of the engine's global `latex-to-svg-font-scale' via
`latex-to-svg-backend's `:rescale-by'.  Re-scales from cache (no recompile);
after changing it, run `latex-to-svg-frontend-refresh' to apply."
  :type 'number
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-display-rescale 1.0
  "Size multiplier for display math previews (`\\[…\\]', `$$…$$', environments).
Applied on top of the engine's global `latex-to-svg-font-scale' via
`latex-to-svg-backend's `:rescale-by' — e.g. set to 1.1 for display equations a
touch larger than inline.  Re-scales from cache (no recompile); after
changing it, run `latex-to-svg-frontend-refresh' to apply."
  :type 'number
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-dollar-inline t
  "Whether to detect inline TeX dollar math `$…$'.
`$' is the least reliable delimiter, since it also occurs in prose (prices,
shell variables).  The scanner already applies pandoc-style guards — an
opening `$' must be followed by a non-space, a closing `$' preceded by a
non-space, and an escaped `\$' is ignored — so spaced currency like
\"$30 and $50\" is not mistaken for math.  What still slips through is a
no-space range such as \"$100-$200\" (the hyphen touches both dollars, so it
reads as the equation `100-').  Turn this off (leaving the other three
families on) in buffers where `$' is mostly currency."
  :type 'boolean
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-dollar-display t
  "Whether to detect display TeX dollar math `$$…$$'.
Safe to keep on even when `latex-to-svg-frontend-detect-dollar-inline' is
off: a doubled `$$' is unlikely to occur by accident in prose."
  :type 'boolean
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-bracket-inline t
  "Whether to detect inline LaTeX bracket math `\\(…\\)'."
  :type 'boolean
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-bracket-display t
  "Whether to detect display LaTeX bracket math `\\[…\\]'."
  :type 'boolean
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-environments t
  "Whether to detect LaTeX environments `\\begin{env}…\\end{env}'."
  :type 'boolean
  :group 'latex-to-svg-frontend)

(defcustom latex-to-svg-frontend-detect-references t
  "Whether to detect `\\eqref' / `\\ref' and show them as resolved numbers.
Only meaningful with `latex-to-svg-frontend-number-equations' on, since the
number comes from the document's `\\label' map.  When off, `\\eqref' / `\\ref'
are left as literal source."
  :type 'boolean
  :group 'latex-to-svg-frontend)

;;;; Per-markup protocol (buffer-local; set by an adaptor's minor mode)

(defvar-local latex-to-svg-frontend-exclude-function nil
  "Function (BEG END) -> list of (B . E) regions where math must be ignored.
A mode adaptor sets this to the buffer's code / verbatim regions so the
scanner skips math inside them.  nil means no exclusions.")

(defvar-local latex-to-svg-frontend-reveal-function nil
  "Function of no args, called after a jump to unfold the target.
E.g. Org sets it to `org-fold-show-context'.  nil means no unfolding.")

(defvar-local latex-to-svg-frontend-detect-function nil
  "Escape hatch: function (BEG END) -> list of math records.
When non-nil it replaces the built-in scanner entirely (see
`latex-to-svg-frontend--detect'); adaptors normally leave this nil.")

(defconst latex-to-svg-frontend--metadata-prefix "L2S="
  "Marker prefix for the `\\typeout' number probe (a distinctive `key='.
Installed as `latex-to-svg-backend-metadata-prefix' so the engine captures the
block's final `equation' counter into its `.eld' sidecar.")

(defface latex-to-svg-frontend-reference '((t :inherit link))
  "Face for inline `\\eqref' / `\\ref' number previews.
These are shown as ordinary buffer text (e.g. `(3)') in this face, not
typeset by LaTeX, so they match the surrounding prose font.  Set it to
`default' for a plain, unlinked look."
  :group 'latex-to-svg-frontend)

;;;; Math element model
;;
;; The scanner produces our own lightweight records (markup parse trees don't
;; expose math generically).  A record has a TYPE (`fragment' or
;; `environment'), its buffer BEGIN / END, and its verbatim source VALUE
;; (delimiters / `\begin…\end' and all — exactly what the engine renders).

(cl-defstruct (latex-to-svg-frontend--math
               (:constructor latex-to-svg-frontend--math-make)
               (:copier nil))
  "A detected LaTeX math span."
  type begin end value)

(defconst latex-to-svg-frontend--element-types '(fragment environment)
  "Math element types rendered as equations.")

(defun latex-to-svg-frontend--display-p (source)
  "Non-nil when math SOURCE is display (environment, `\\[…\\]', or `$$…$$').
Inline `$…$' / `\\(…\\)' return nil."
  (let ((s (string-trim-left source)))
    (or (string-prefix-p "\\begin" s)
        (string-prefix-p "\\[" s)
        (string-prefix-p "$$" s))))

(defun latex-to-svg-frontend--rescale-for (display-p)
  "Return the `:rescale-by' factor for a DISPLAY-P (else inline) preview."
  (if display-p
      latex-to-svg-frontend-display-rescale
    latex-to-svg-frontend-inline-rescale))

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
A value of `latex-to-svg-backend-appearance', compared against the current one
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

(defun latex-to-svg-frontend--family-enabled-p (tok)
  "Non-nil when opener TOK's delimiter family is enabled by its `-detect-*' toggle."
  (cond
   ((equal tok "$$") latex-to-svg-frontend-detect-dollar-display)
   ((equal tok "$") latex-to-svg-frontend-detect-dollar-inline)
   ((equal tok "\\[") latex-to-svg-frontend-detect-bracket-display)
   ((equal tok "\\(") latex-to-svg-frontend-detect-bracket-inline)
   ((string-prefix-p "\\begin{" tok) latex-to-svg-frontend-detect-environments)
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
LIMIT (the block end).  Skips escaped `\\$', treats a `$$' as not-a-close,
and requires the closing `$' to not follow whitespace (a pandoc-style
guard against stray currency dollars)."
  (save-excursion
    (goto-char from)
    (catch 'done
      (while (re-search-forward "\\$" limit t)
        (let ((p (match-beginning 0)))
          (cond
           ((latex-to-svg-frontend--escaped-p p) nil) ; \$, keep looking
           ((eq (char-after (match-end 0)) ?$)            ; part of a $$
            (goto-char (1+ (match-end 0))))
           ((memq (char-before p) '(?\s ?\t ?\n)) nil)    ; " $" not a close
           ((<= p from) nil)                              ; empty span
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

(defun latex-to-svg-frontend--context ()
  "Return the math record at point, or nil."
  (latex-to-svg-frontend--element-at (point)))

(defun latex-to-svg-frontend--element-bounds (el)
  "Return (BEG . END) covering EL's source text."
  (cons (latex-to-svg-frontend--math-begin el)
        (latex-to-svg-frontend--math-end el)))

;;;; Overlays

(defun latex-to-svg-frontend--overlays-in (beg end)
  "Return this package's overlays intersecting BEG..END."
  (seq-filter (lambda (o) (overlay-get o 'latex-to-svg-frontend))
              (overlays-in beg end)))

(defun latex-to-svg-frontend--clear-region (beg end)
  "Delete this package's preview overlays intersecting BEG..END."
  (mapc #'delete-overlay (latex-to-svg-frontend--overlays-in beg end)))

(defun latex-to-svg-frontend--set-overlay (beg end value image &optional source enums-fallback display-p)
  "Overlay BEG..END (positions or markers) with IMAGE, keyed to render VALUE.
VALUE is the exact string handed to the engine (a numbered environment
carries its `\\setcounter' prefix); SOURCE, if given, is the human-readable
LaTeX shown in `help-echo'.  ENUMS-FALLBACK, when non-nil, marks this as a
numbered equation and records its (INITIAL . FINAL) number range in
`latex-to-svg-frontend-enums'.  Replaces any existing preview overlay
in the span."
  (let ((b (if (markerp beg) (marker-position beg) beg))
        (e (if (markerp end) (marker-position end) end)))
    (when (and b e (< b e) (<= (point-min) b) (<= e (point-max)))
      (latex-to-svg-frontend--clear-region b e)
      (let ((ov (make-overlay b e)))
        (overlay-put ov 'latex-to-svg-frontend t)
        (overlay-put ov 'latex-to-svg-frontend-value value)
        ;; Raw LaTeX (no `\setcounter' prefix) so a numbered overlay can be
        ;; renumbered from itself, without re-scanning buffer text.
        (overlay-put ov 'latex-to-svg-frontend-source (or source value))
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'help-echo (or source value))
        (overlay-put ov 'display image)
        (overlay-put ov 'latex-to-svg-frontend-display-math display-p)
        (overlay-put ov 'latex-to-svg-frontend-image image)
        (when enums-fallback
          (let ((meta (plist-get (latex-to-svg-backend-metadata value) :nums)))
            (overlay-put ov 'latex-to-svg-frontend-enums (or meta enums-fallback))
            (when (and meta (not (equal meta enums-fallback)))
              (latex-to-svg-frontend--schedule-reconcile))))
        (overlay-put ov 'modification-hooks
                     (list #'latex-to-svg-frontend--on-modify))
        (setq latex-to-svg-frontend--rendered-appearance (latex-to-svg-backend-appearance))
        ov))))

;;;; Reveal on cursor entry

(defvar-local latex-to-svg-frontend--last-point nil
  "Marker at point after the previous command (for cursor reveal tracking).")

(defun latex-to-svg-frontend--on-modify (ov after &rest _)
  "Modification hook for preview OV: reveal its source, flag it for re-render."
  (when after
    (overlay-put ov 'latex-to-svg-frontend-modified t)
    (overlay-put ov 'display nil)))

(defun latex-to-svg-frontend--revealable-overlay-at (pos)
  "Return this package's preview overlay covering POS, or nil.
Both image previews and `\\eqref' / `\\ref' text previews qualify."
  (seq-find (lambda (o) (or (overlay-get o 'latex-to-svg-frontend-image)
                            (overlay-get o 'latex-to-svg-frontend-ref)))
            (overlays-at pos)))

(defun latex-to-svg-frontend--open-overlay (ov)
  "Reveal OV's LaTeX source by hiding its image / reference text."
  (overlay-put ov 'display nil))

(defun latex-to-svg-frontend--close-overlay (ov)
  "Re-show OV's preview, or re-render it if its source was edited while open."
  (when (overlay-buffer ov)
    (cond
     ((overlay-get ov 'latex-to-svg-frontend-modified)
      (overlay-put ov 'latex-to-svg-frontend-modified nil)
      (latex-to-svg-frontend--rerender-overlay ov))
     ((overlay-get ov 'latex-to-svg-frontend-image)
      (overlay-put ov 'display (overlay-get ov 'latex-to-svg-frontend-image)))
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
        (delete-overlay ov)))))

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
  "Reveal the preview point moved into, re-hide the one it left, and render
any newly finished equation the cursor just left.
On `post-command-hook' while the mode is on."
  (when latex-to-svg-frontend-mode
    (let ((last (and latex-to-svg-frontend--last-point
                     (marker-position latex-to-svg-frontend--last-point))))
      ;; Render an equation the cursor just left (event-driven, no idle timer).
      (when (and last (/= last (point)))
        (latex-to-svg-frontend--render-on-leave last (point)))
      (let* ((prev (and last (latex-to-svg-frontend--revealable-overlay-at last)))
             (cur (latex-to-svg-frontend--revealable-overlay-at (point))))
      (when (and prev (not (eq prev cur)))
        (latex-to-svg-frontend--close-overlay prev))
      (when (and cur (not (eq cur prev))
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
and makes the span click-to-jump (`mouse-1' / `RET') to the equation
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
        (overlay-put ov 'keymap latex-to-svg-frontend--reference-keymap)
        (overlay-put ov 'mouse-face 'highlight)
        (overlay-put ov 'help-echo
                     (format "mouse-1: jump to the equation labelled %s" label))
        (overlay-put ov 'modification-hooks
                     (list #'latex-to-svg-frontend--on-modify))
        ov))))

;;;; Numbering

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
      (while (re-search-forward "\\\\nonumber\\|\\\\notag\\|\\\\tag{" nil t)
        (cl-incf suppressed))
      (max 0 (- rows suppressed)))))

(defun latex-to-svg-frontend--count-numbered-equations (value)
  "Return how many numbered equations the environment source VALUE consumes.
Unknown / non-numbered environments (and starred forms) consume 0."
  (let ((env (latex-to-svg-frontend--environment-name value)))
    (cond
     ((member env latex-to-svg-frontend--numbered-environments-single)
      (if (string-match-p "\\\\nonumber\\|\\\\notag\\|\\\\tag{" value) 0 1))
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

(defun latex-to-svg-frontend--multi-row-labels (value env offset)
  "Return an alist of (LABEL . NUMBER) for multi-equation source VALUE.
ENV is the environment name; OFFSET the counter before the block."
  (with-temp-buffer
    (insert value)
    (goto-char (point-min))
    (when (re-search-forward (concat "\\\\begin{" (regexp-quote env) "}") nil t)
      (delete-region (point-min) (point)))
    (goto-char (point-max))
    (when (re-search-backward (concat "\\\\end{" (regexp-quote env) "}") nil t)
      (delete-region (match-beginning 0) (point-max)))
    (let ((rows nil) (depth 0) (row-start (point-min)))
      (goto-char (point-min))
      (while (re-search-forward "\\\\begin{[^}]+}\\|\\\\end{[^}]+}\\|\\\\\\\\" nil t)
        (let ((m (match-string 0)))
          (cond
           ((string-prefix-p "\\begin" m) (cl-incf depth))
           ((string-prefix-p "\\end" m) (setq depth (max 0 (1- depth))))
           ((= depth 0)
            (push (buffer-substring-no-properties row-start (match-beginning 0)) rows)
            (setq row-start (match-end 0))))))
      (push (buffer-substring-no-properties row-start (point-max)) rows)
      (setq rows (nreverse rows))
      (let ((num (1+ offset)) (out nil))
        (dolist (row rows)
          (if (string-match-p "\\\\nonumber\\|\\\\notag\\|\\\\tag{" row)
              nil
            (dolist (name (latex-to-svg-frontend--labels-in row))
              (push (cons name num) out))
            (cl-incf num)))
        (nreverse out)))))

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
their final counter into the engine's `.eld' sidecar."
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

(defun latex-to-svg-frontend--reference-display (source labels)
  "If SOURCE is a resolvable `\\eqref' / `\\ref' fragment, return its display text.
`\\eqref' -> \"(N)\", `\\ref' -> \"N\" — plain buffer text — or nil."
  (when-let* ((parsed (latex-to-svg-frontend--reference-parse source))
              (num (gethash (cdr parsed) labels)))
    (if (equal (car parsed) "eqref") (format "(%d)" num) (number-to-string num))))

(defun latex-to-svg-frontend--reference-display-text (kind num)
  "Return the buffer-text display for a KIND (\"eqref\"/\"ref\") reference to NUM.
NUM nil (an unknown or just-deleted target) shows \"(??)\" / \"??\" so a
dangling reference is visibly broken rather than stale."
  (propertize
   (cond ((null num) (if (equal kind "eqref") "(??)" "??"))
         ((equal kind "eqref") (format "(%d)" num))
         (t (number-to-string num)))
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

(defun latex-to-svg-frontend--numbered-value (el source table)
  "Return the exact engine string for EL: SOURCE, adjusted for numbering.
TABLE is a (OFFSETS . LABELS) scan."
  (let ((k (and (car-safe table)
                (gethash (latex-to-svg-frontend--math-begin el) (car-safe table)))))
    (if k (latex-to-svg-frontend--setcounter-value k source) source)))

;;;; Rendering

(defun latex-to-svg-frontend--place (buffer beg end value &optional source enums-fallback display-p)
  "Ensure BUFFER's BEG..END shows the current image for render VALUE.
Overlays immediately on a cache hit, else schedules an async compile and
overlays when it finishes.  BEG / END should be markers."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((image (latex-to-svg-backend
                    value
                    :rescale-by (latex-to-svg-frontend--rescale-for display-p)
                    :metadata (car enums-fallback)
                    :callback (lambda ()
                                (latex-to-svg-frontend--place
                                 buffer beg end value source enums-fallback display-p)))))
        (when image
          (latex-to-svg-frontend--set-overlay beg end value image source enums-fallback display-p))))))

(defun latex-to-svg-frontend--render-numbered (el k)
  "Render numbered environment EL starting at counter K."
  (let* ((bounds (latex-to-svg-frontend--element-bounds el))
         (source (latex-to-svg-frontend--math-value el))
         (value (latex-to-svg-frontend--setcounter-value k source))
         (heuristic (latex-to-svg-frontend--count-numbered-equations source)))
    (latex-to-svg-frontend--place (current-buffer)
                                      (copy-marker (car bounds))
                                      (copy-marker (cdr bounds))
                                      value source (cons (1+ k) (+ k heuristic))
                                      (latex-to-svg-frontend--display-p source))))

(defun latex-to-svg-frontend--render-element (el &optional table)
  "Render math element EL in the current buffer.
TABLE is a (OFFSETS . LABELS) numbering scan; when omitted one is built
on demand.  An `\\eqref' / `\\ref' is drawn as clickable buffer text (its
number, or `(??)' when the label is unknown), a numbered environment via
`--render-numbered'; everything else is typeset verbatim by the engine."
  (let* ((bounds (latex-to-svg-frontend--element-bounds el))
         (source (latex-to-svg-frontend--math-value el))
         (table (or table (latex-to-svg-frontend--maybe-table)))
         (offsets (car-safe table))
         (labels (cdr-safe table))
         (parsed (and latex-to-svg-frontend-detect-references labels
                      (eq (latex-to-svg-frontend--math-type el) 'fragment)
                      (latex-to-svg-frontend--reference-parse source)))
         (k (and offsets (gethash (latex-to-svg-frontend--math-begin el) offsets))))
    (cond
     (parsed
      (let ((num (gethash (cdr parsed) labels)))
        (latex-to-svg-frontend--set-reference-overlay
         (copy-marker (car bounds)) (copy-marker (cdr bounds))
         (cdr parsed) num
         (latex-to-svg-frontend--reference-display-text (car parsed) num))))
     (k (latex-to-svg-frontend--render-numbered el k))
     (t (latex-to-svg-frontend--place (current-buffer)
                                          (copy-marker (car bounds))
                                          (copy-marker (cdr bounds))
                                          source source nil
                                          (latex-to-svg-frontend--display-p source))))))

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
  "Re-render numbered overlay OV at counter K, reusing its stored source."
  (let* ((source (overlay-get ov 'latex-to-svg-frontend-source))
         (value (latex-to-svg-frontend--setcounter-value k source))
         (heuristic (latex-to-svg-frontend--count-numbered-equations source)))
    (latex-to-svg-frontend--place
     (current-buffer)
     (copy-marker (overlay-start ov)) (copy-marker (overlay-end ov))
     value source (cons (1+ k) (+ k heuristic))
     (latex-to-svg-frontend--display-p source))))

(defun latex-to-svg-frontend--reconcile-from (pos)
  "Renumber from the just-rendered equation at POS downward, then re-resolve refs.
Assumes overlays before POS are already consistent (true after a discrete
cursor-leave render).  Walks numbered overlays from POS on, seeding the
counter from the preceding overlay, re-rendering each whose number shifted,
and stopping as soon as numbers realign.  Falls back to a full
`--reconcile' on any structural surprise (a downstream overlay with no
usable source).  No-op unless the mode and numbering are on."
  (when (and (bound-and-true-p latex-to-svg-frontend-mode)
             latex-to-svg-frontend-number-equations)
    (if (not latex-to-svg-frontend-incremental-reconcile)
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
                  (when (overlay-get ov 'display)
                    (latex-to-svg-frontend--renumber-overlay ov k)))
                (setq k (+ k (max 0 (- (cdr enums) (car enums) -1))))))))
        (if fell-back
            (latex-to-svg-frontend--reconcile)
          (latex-to-svg-frontend--reconcile-references
           (latex-to-svg-frontend--overlay-labels)))))))

(defun latex-to-svg-frontend--reconcile-references (labels)
  "Re-resolve every reference preview against LABELS, patching its text.
Covers all transitions: a shifted number, a deleted target (number ->
`(??)'), and a target that became defined (`(??)' -> a number).  Uses the
reference's current buffer text for the label, so it also follows a label
edited in place.  Skips a reference revealed for editing (`display' nil)."
  (dolist (ov (latex-to-svg-frontend--overlays-in (point-min) (point-max)))
    (when-let* ((name (overlay-get ov 'latex-to-svg-frontend-ref))
                (parsed (latex-to-svg-frontend--reference-parse
                         (buffer-substring-no-properties
                          (overlay-start ov) (overlay-end ov)))))
      (let ((want (gethash (cdr parsed) labels)))
        (unless (eql want (overlay-get ov 'latex-to-svg-frontend-ref-num))
          (let ((disp (latex-to-svg-frontend--reference-display-text
                       (car parsed) want)))
            (overlay-put ov 'latex-to-svg-frontend-ref-display disp)
            (when (overlay-get ov 'display)
              (overlay-put ov 'display disp))
            (overlay-put ov 'latex-to-svg-frontend-ref-num want)))))))

(defvar-local latex-to-svg-frontend--reconcile-timer nil
  "Pending debounced reconcile timer for this buffer.")

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
wider and the pass is kept \=-- the incremental leave cannot see undrawn
equations, so the full scan is still needed."
  (when (and latex-to-svg-frontend--dirty
             (>= (car latex-to-svg-frontend--dirty) beg)
             (<= (cdr latex-to-svg-frontend--dirty) end))
    (latex-to-svg-frontend--cancel-reconcile)))

(defun latex-to-svg-frontend--reconcile (&optional buffer)
  "Recompute equation numbers and re-render previews whose number changed.
A comprehensive pass: also cancels any pending debounced reconcile and clears
the pending-change range.  No-op unless the mode and numbering are on."
  (with-current-buffer (or buffer (current-buffer))
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
                (when (and ov
                           (overlay-get ov 'display)
                           (not (equal (car enums) (1+ k))))
                  (latex-to-svg-frontend--render-numbered el k))
                (setq k (+ k (max 0 consumed)))))))
        (latex-to-svg-frontend--reconcile-references
         (cdr (latex-to-svg-frontend--scan-numbering envs))))
      (latex-to-svg-frontend--cancel-reconcile))))

(defun latex-to-svg-frontend--schedule-reconcile (&optional beg end _len)
  "Debounce a numbering reconcile of the current buffer (see `--reconcile').
Hooked to `after-change-functions' (which passes BEG END _LEN) and also
fired with no arguments when ground truth corrects a heuristic guess.  A
backstop that re-renders any preview edited and left (`--heal-modified')
and renumbers downstream; the initial render of newly typed math is handled
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
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq latex-to-svg-frontend--reconcile-timer nil)
                   (when (bound-and-true-p latex-to-svg-frontend-mode)
                     (latex-to-svg-frontend--heal-modified))
                   (latex-to-svg-frontend--reconcile buf)))))))))

;;;; Refresh (theme / font tracking)

(defun latex-to-svg-frontend--refresh-buffer (buffer)
  "Re-tint / re-scale BUFFER's previews for the current appearance."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (ov (latex-to-svg-frontend--overlays-in (point-min) (point-max)))
        (when-let* ((value (overlay-get ov 'latex-to-svg-frontend-value))
                    (image (latex-to-svg-backend
                            value :rescale-by
                            (latex-to-svg-frontend--rescale-for
                             (overlay-get ov 'latex-to-svg-frontend-display-math)))))
          (overlay-put ov 'latex-to-svg-frontend-image image)
          (when (overlay-get ov 'display)
            (overlay-put ov 'display image))))
      (setq latex-to-svg-frontend--rendered-appearance (latex-to-svg-backend-appearance)))))

;;;###autoload
(defun latex-to-svg-frontend-refresh (&optional buffer)
  "Re-render previews in BUFFER (default current) for the current theme and font."
  (interactive)
  (latex-to-svg-frontend--refresh-buffer (or buffer (current-buffer))))

(defun latex-to-svg-frontend--present-p ()
  "Return non-nil if the current buffer has preview overlays."
  (and latex-to-svg-frontend-mode
       (latex-to-svg-frontend--overlays-in (point-min) (point-max))))

(defun latex-to-svg-frontend--refresh-if-changed ()
  "Refresh the current buffer's previews if its appearance changed."
  (when (and (latex-to-svg-frontend--present-p)
             (not (equal (latex-to-svg-backend-appearance)
                         latex-to-svg-frontend--rendered-appearance)))
    (latex-to-svg-frontend-refresh (current-buffer))))

(defun latex-to-svg-frontend--maybe-refresh (&rest _)
  "Schedule a lazy appearance-changed refresh of the current buffer."
  (when latex-to-svg-frontend-mode
    (let ((buf (current-buffer)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (latex-to-svg-frontend--refresh-if-changed))))))))

(defun latex-to-svg-frontend--on-theme-change (&rest _)
  "Refresh every preview buffer whose appearance changed after a theme switch."
  (run-at-time
   0 nil
   (lambda ()
     (dolist (buf (buffer-list))
       (when (buffer-local-value 'latex-to-svg-frontend-mode buf)
         (with-current-buffer buf
           (latex-to-svg-frontend--refresh-if-changed)))))))

(add-hook 'enable-theme-functions #'latex-to-svg-frontend--on-theme-change)
(add-hook 'text-scale-mode-hook #'latex-to-svg-frontend--maybe-refresh)
(add-hook 'window-buffer-change-functions #'latex-to-svg-frontend--maybe-refresh)

;;;; Command and mode

(defun latex-to-svg-frontend--ref-overlay-at (pos)
  "Return this package's reference overlay covering POS, or nil."
  (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
            (overlays-in (max (point-min) (1- pos))
                         (min (point-max) (1+ pos)))))

(defun latex-to-svg-frontend-goto-reference (&optional event)
  "Jump to the equation defining the label of the reference preview at point.
Bound in `\\eqref' / `\\ref' preview overlays to `mouse-1' and `RET'."
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
     ((null pos) (user-error "Cannot find an equation labelled %s" label))
     (t (push-mark)
        (goto-char pos)
        (when latex-to-svg-frontend-reveal-function
          (funcall latex-to-svg-frontend-reveal-function))
        (when (get-buffer-window (current-buffer)) (recenter))
        (message "Jumped to \\label{%s}" label)))))

(defvar latex-to-svg-frontend--reference-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'latex-to-svg-frontend-goto-reference)
    (define-key map (kbd "RET") #'latex-to-svg-frontend-goto-reference)
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

;;;###autoload
(defun latex-to-svg-frontend-regenerate (&optional beg end)
  "Force a fresh recompile of previews in BEG..END.

Deletes each equation's cached SVG (via `latex-to-svg-backend-invalidate') and
clears its overlay, then re-renders — bypassing the content-addressed
cache.  Interactively acts on the active region, or the whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (point-min) (point-max))))
  (let ((beg (or beg (point-min)))
        (end (or end (point-max)))
        (table (latex-to-svg-frontend--maybe-table)))
    (dolist (el (latex-to-svg-frontend--elements beg end))
      (latex-to-svg-backend-invalidate
       (latex-to-svg-frontend--numbered-value
        el (latex-to-svg-frontend--math-value el) table)))
    (latex-to-svg-frontend--clear-region beg end)
    (latex-to-svg-frontend--render-region beg end)))

;;;###autoload
(defun latex-to-svg-frontend (&optional arg)
  "Preview LaTeX math as SVG images.

With no prefix ARG: toggle the fragment at point; or, with an active
region, render that region; or, failing both, render the whole buffer.

With a `\\[universal-argument]' prefix, re-render the whole buffer (clear
then render) — rebuilds overlays from cache, fixing a stale display.

With a `\\[universal-argument] \\[universal-argument]' prefix, regenerate
the whole buffer: a fresh recompile bypassing the cache (see
`latex-to-svg-frontend-regenerate')."
  (interactive "P")
  (cond
   ((equal arg '(16))
    (latex-to-svg-frontend-regenerate (point-min) (point-max))
    (message "Regenerated LaTeX previews"))
   ((equal arg '(4))
    (latex-to-svg-frontend--clear-region (point-min) (point-max))
    (latex-to-svg-frontend--render-region (point-min) (point-max))
    (message "Re-rendered LaTeX previews"))
   ((use-region-p)
    (latex-to-svg-frontend--render-region (region-beginning) (region-end))
    (latex-to-svg-frontend--reconcile)
    (deactivate-mark))
   ((latex-to-svg-frontend--context)
    (let* ((el (latex-to-svg-frontend--context))
           (b (latex-to-svg-frontend--math-begin el))
           (e (latex-to-svg-frontend--math-end el)))
      (if (latex-to-svg-frontend--overlays-in b e)
          (latex-to-svg-frontend--clear-region b e)
        (latex-to-svg-frontend--render-element el)
        (latex-to-svg-frontend--reconcile))))
   (t
    (latex-to-svg-frontend--render-region (point-min) (point-max))
    (latex-to-svg-frontend--reconcile))))

(defvar latex-to-svg-frontend-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-x C-l") #'latex-to-svg-frontend)
    map)
  "Keymap for `latex-to-svg-frontend-mode'.")

;;;###autoload
(define-minor-mode latex-to-svg-frontend-mode
  "Minor mode previewing LaTeX math as SVG images via `latex-to-svg-backend'.

This is the shared core; normally you enable it through a per-markup
adaptor mode (e.g. `latex-to-svg-for-markdown-mode') that first installs
the buffer-local protocol (`latex-to-svg-frontend-exclude-function' etc.).
When enabled, all detected math is rendered; disabling clears it.  See
`latex-to-svg-frontend' for the command bound to \\[latex-to-svg-frontend]."
  :lighter " L2S"
  :keymap latex-to-svg-frontend-mode-map
  (if latex-to-svg-frontend-mode
      (progn
        (add-hook 'after-change-functions
                  #'latex-to-svg-frontend--schedule-reconcile nil t)
        (add-hook 'post-command-hook
                  #'latex-to-svg-frontend--handle-cursor nil t)
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
    (remove-hook 'after-change-functions
                 #'latex-to-svg-frontend--schedule-reconcile t)
    (remove-hook 'post-command-hook #'latex-to-svg-frontend--handle-cursor t)
    (when (markerp latex-to-svg-frontend--last-point)
      (set-marker latex-to-svg-frontend--last-point nil))
    (setq latex-to-svg-frontend--last-point nil)
    (when (timerp latex-to-svg-frontend--reconcile-timer)
      (cancel-timer latex-to-svg-frontend--reconcile-timer)
      (setq latex-to-svg-frontend--reconcile-timer nil))
    (latex-to-svg-frontend--clear-region (point-min) (point-max))
    (setq latex-to-svg-frontend--rendered-appearance nil)))

(provide 'latex-to-svg-frontend)

;;; latex-to-svg-frontend.el ends here
