;;; org-latex-to-svg.el --- Preview Org LaTeX math as SVG via latex-to-svg -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; URL: https://github.com/alberti42/org-latex-to-svg
;; Version: 0.7.0
;; Package-Requires: ((emacs "29.1") (latex-to-svg "0.3.1"))
;; Keywords: tex, org, math, images

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
;; An Org front-end over the `latex-to-svg' rendering engine.  It finds
;; `latex-fragment' and `latex-environment' elements with `org-element' and
;; overlays each with an SVG image typeset by `latex-to-svg'.
;;
;; Because the engine renders its input *verbatim*, the front-end simply
;; passes each element's `:value' (which already carries its delimiters or
;; `\\begin{...}...\\end{...}') — no stripping, no wrapping; inline vs display
;; sizing follows from the delimiters.
;;
;; The engine compiles each unique equation once (content-addressed on disk),
;; color-independent (`--currentcolor', tinted at display) and size-independent
;; (scaled at display to the buffer font).  So this front-end gets, for free,
;; the thing built-in Org's classic preview cannot do: on an OS light/dark
;; theme switch or a buffer text-zoom, previews re-tint / re-scale straight
;; from the cache with NO LaTeX recompile.
;;
;; Usage:
;;
;;   (add-hook 'org-mode-hook #'org-latex-to-svg-mode)
;;
;; then `C-c C-x C-l' (`org-latex-to-svg') toggles the fragment at point,
;; renders the region, or (failing both) the whole buffer; `C-u C-c C-x C-l'
;; clears all previews.  `M-x org-latex-to-svg-refresh' forces a re-render for
;; the current theme / font size (previews also refresh lazily on theme,
;; buffer-display, and zoom changes).
;;
;; Inline and display math can be sized independently with
;; `org-latex-to-svg-inline-rescale' / `-display-rescale' (multipliers on top of
;; the engine's `latex-to-svg-font-scale'); they re-scale from cache, so
;; `org-latex-to-svg-refresh' applies a change with no recompile.
;;
;; Numbered display environments (`equation', `align', …) get their real
;; document-wide number via `org-latex-to-svg-number-equations' (on by
;; default): the count of preceding numbered equations is computed in Elisp
;; and baked in as a `\\setcounter' prefix, so the number is part of the
;; engine's content hash (see docs/numbering.md).  `\\eqref' / `\\ref' are resolved
;; against a `\\label' -> number map built in the same scan and shown as plain
;; buffer text (e.g. `(3)', in the `org-latex-to-svg-reference' face — not a
;; LaTeX image, so it matches the surrounding font); their previews are
;; click-to-jump (mouse-1 / RET) to the equation defining the label.  Like an
;; image preview, a reference reveals its `\eqref' / `\ref' source on cursor
;; entry so you can edit the label, then re-renders on leave.
;;
;; Numbers are kept correct as you edit: each numbered block is rendered with a
;; `\\typeout' probe so the engine caches its true final counter (ground truth),
;; and a debounced reconcile threads the counter over the document, re-rendering
;; only previews whose number changed (`org-latex-to-svg--reconcile').  The
;; Elisp heuristic is a fast first guess; the cached metadata corrects it.
;;
;; Move point into a preview (image or reference) and it reveals its LaTeX
;; source for editing; leaving re-shows the preview, or re-renders it if you
;; changed the text (`org-latex-to-svg--handle-cursor', on `post-command-hook').
;; Newly typed math renders the moment the cursor leaves it
;; (`org-latex-to-svg--render-left'), never while still inside — so half-typed
;; equations are not compiled, and new equations appear without invoking the
;; render command.

;;; Code:

(require 'latex-to-svg)
(require 'org-element)
(require 'seq)
(require 'cl-lib)

(defgroup org-latex-to-svg nil
  "Preview Org LaTeX math as SVG images via `latex-to-svg'."
  :group 'org
  :prefix "org-latex-to-svg-")

(defcustom org-latex-to-svg-number-equations t
  "Whether to compute and bake equation numbers into display-math previews.

When non-nil, numbered LaTeX environments (`equation', `align', …) are
rendered with a `\\setcounter{equation}{N}' prefix so each preview shows
its real document-wide number.  N is derived purely in Elisp by counting
the numbered equations that precede the block (see docs/numbering.md); the
number is part of the engine's content hash, so a block re-renders only
when its number actually changes.

When nil, every element renders verbatim (no numbering)."
  :type 'boolean
  :group 'org-latex-to-svg)

(defcustom org-latex-to-svg-reconcile-idle 0.4
  "Idle seconds before equation numbers are reconciled after an edit.
When numbering is on, editing schedules a debounced pass that re-renders
any downstream preview whose number changed (see
`org-latex-to-svg--reconcile').  nil disables the automatic pass (numbers
then refresh only on an explicit render)."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'org-latex-to-svg)

(defcustom org-latex-to-svg-inline-rescale 1.0
  "Size multiplier for inline math previews (`$…$', `\\(…\\)').
Applied on top of the engine's global `latex-to-svg-font-scale' via
`latex-to-svg's `:rescale-by'.  Re-scales from cache (no recompile);
after changing it, run `org-latex-to-svg-refresh' to apply."
  :type 'number
  :group 'org-latex-to-svg)

(defcustom org-latex-to-svg-display-rescale 1.0
  "Size multiplier for display math previews (`\\[…\\]', `$$…$$', environments).
Applied on top of the engine's global `latex-to-svg-font-scale' via
`latex-to-svg's `:rescale-by' — e.g. set to 1.1 for display equations a
touch larger than inline.  Re-scales from cache (no recompile); after
changing it, run `org-latex-to-svg-refresh' to apply."
  :type 'number
  :group 'org-latex-to-svg)

(defconst org-latex-to-svg--metadata-prefix "L2S="
  "Marker prefix for the `\\typeout' number probe (a distinctive `key='.
Installed as `latex-to-svg-metadata-prefix' so the engine captures the
block's final `equation' counter into its `.eld' sidecar.")

(defface org-latex-to-svg-reference '((t :inherit org-link))
  "Face for inline `\\eqref' / `\\ref' number previews.
These are shown as ordinary buffer text (e.g. `(3)') in this face, not
typeset by LaTeX, so they match the surrounding prose font.  Set it to
`default' for a plain, unlinked look."
  :group 'org-latex-to-svg)

(defconst org-latex-to-svg--element-types '(latex-fragment latex-environment)
  "Org element types rendered as equations.")

(defun org-latex-to-svg--display-p (source)
  "Non-nil when math SOURCE is display (environment, `\\[…\\]', or `$$…$$').
Inline `$…$' / `\\(…\\)' return nil."
  (let ((s (string-trim-left source)))
    (or (string-prefix-p "\\begin" s)
        (string-prefix-p "\\[" s)
        (string-prefix-p "$$" s))))

(defun org-latex-to-svg--rescale-for (display-p)
  "Return the `:rescale-by' factor for a DISPLAY-P (else inline) preview."
  (if display-p
      org-latex-to-svg-display-rescale
    org-latex-to-svg-inline-rescale))

(defconst org-latex-to-svg--numbered-environments-single
  '("equation" "math" "displaymath" "multline" "dmath" "empheq")
  "LaTeX environments that produce a single numbered equation.
`multline' lives here (not with the multi-row environments): it typesets
one number for the whole line-broken equation, so its `\\\\' are line
breaks, not equation separators.  Mirrors the reference implementation in
tecosaur's `org-latex-preview.el', with `multline' corrected.")

(defconst org-latex-to-svg--numbered-environments-multi
  '("eqnarray" "align" "alignat" "flalign" "gather"
    "xalignat" "xxalignat" "subequations" "dseries" "dgroup" "darray")
  "LaTeX environments that produce one numbered equation per row.
`subequations' is best-effort (its inner environments are counted, but
the `N.a'/`N.b' sub-lettering is not modelled).")

(defconst org-latex-to-svg--numbered-environments-all
  (append org-latex-to-svg--numbered-environments-single
          org-latex-to-svg--numbered-environments-multi)
  "All LaTeX environments that produce numbered equations.")

;; Forward declaration: the minor-mode variable is defined by the
;; `define-minor-mode' at the end of the file but referenced by the refresh
;; helpers above it.
(defvar org-latex-to-svg-mode)

;; Forward declaration: the reference-overlay keymap is defined with the
;; interactive commands near the end of the file, but `--set-overlay' (above it)
;; installs it on `\eqref' / `\ref' previews.
(defvar org-latex-to-svg--reference-keymap)

(defvar-local org-latex-to-svg--rendered-appearance nil
  "Appearance signature this buffer's previews were last rendered for.
A value of `latex-to-svg-appearance', compared against the current one
so a lazy refresh can detect a theme or font-size change and re-tint /
re-scale from cache.")

;;;; Element detection

(defun org-latex-to-svg--element-bounds (el)
  "Return (BEG . END) covering EL's source text, trimming trailing blanks.
Org's `:end' includes `:post-blank' whitespace / blank lines; the
overlay should cover only the fragment itself, so trim back to the
last non-blank character."
  (let ((beg (org-element-property :begin el))
        (end (org-element-property :end el)))
    (cons beg
          (save-excursion
            (goto-char end)
            (skip-chars-backward " \t\n" beg)
            (point)))))

(defun org-latex-to-svg--elements (beg end)
  "Return the math elements whose span overlaps BEG..END.
Parses the whole (widened) buffer with `org-element' and keeps
`org-latex-to-svg--element-types' elements intersecting the range."
  (save-restriction
    (widen)
    (org-element-map (org-element-parse-buffer) org-latex-to-svg--element-types
      (lambda (el)
        (and (< (org-element-property :begin el) end)
             (> (org-element-property :end el) beg)
             el)))))

(defun org-latex-to-svg--context ()
  "Return the math element at point, or nil."
  (let ((el (org-element-context)))
    (and (memq (org-element-type el) org-latex-to-svg--element-types) el)))

;;;; Overlays

(defun org-latex-to-svg--overlays-in (beg end)
  "Return this package's overlays intersecting BEG..END."
  (seq-filter (lambda (o) (overlay-get o 'org-latex-to-svg))
              (overlays-in beg end)))

(defun org-latex-to-svg--clear-region (beg end)
  "Delete this package's preview overlays intersecting BEG..END."
  (mapc #'delete-overlay (org-latex-to-svg--overlays-in beg end)))

(defun org-latex-to-svg--clear-native (beg end)
  "Delete Org's built-in `org-latex-preview' image overlays in BEG..END.
With this mode on, `org-latex-to-svg' owns the previews for these
fragments; a leftover native overlay (from `#+STARTUP: latexpreview' or a
prior `org-latex-preview') would otherwise stack its own image under
ours — visible again when ours is revealed on cursor entry."
  (dolist (o (overlays-in beg end))
    (when (eq (overlay-get o 'org-overlay-type) 'org-latex-overlay)
      (delete-overlay o))))

(defun org-latex-to-svg--set-overlay (beg end value image &optional source enums-fallback display-p)
  "Overlay BEG..END (positions or markers) with IMAGE, keyed to render VALUE.
VALUE is the exact string handed to the engine (a numbered environment
carries its `\\setcounter' prefix) so a cache refresh re-fetches the same
hash; SOURCE, if given, is the human-readable LaTeX shown in `help-echo'.
ENUMS-FALLBACK, when non-nil, marks this as a numbered equation: the
overlay records its (INITIAL . FINAL) number range in
`org-latex-to-svg-enums', taken from the engine's `.eld' metadata when
available, else from this heuristic fallback.  Replaces any existing
preview overlay in the span; clears itself when the text is edited."
  (let ((b (if (markerp beg) (marker-position beg) beg))
        (e (if (markerp end) (marker-position end) end)))
    (when (and b e (< b e) (<= (point-min) b) (<= e (point-max)))
      (org-latex-to-svg--clear-region b e)
      (org-latex-to-svg--clear-native b e)
      (let ((ov (make-overlay b e)))
        (overlay-put ov 'org-latex-to-svg t)
        (overlay-put ov 'org-latex-to-svg-value value)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'help-echo (or source value))
        (overlay-put ov 'display image)
        ;; Remember inline-vs-display so a refresh re-scales by the right factor.
        (overlay-put ov 'org-latex-to-svg-display-math display-p)
        ;; Keep the image so cursor-reveal can restore it (see
        ;; `org-latex-to-svg--close-overlay').
        (overlay-put ov 'org-latex-to-svg-image image)
        (when enums-fallback
          (let ((meta (plist-get (latex-to-svg-metadata value) :nums)))
            (overlay-put ov 'org-latex-to-svg-enums (or meta enums-fallback))
            ;; Ground truth disagreed with the heuristic: numbers below may
            ;; shift, so schedule a reconcile to correct them.
            (when (and meta (not (equal meta enums-fallback)))
              (org-latex-to-svg--schedule-reconcile))))
        ;; On edit: reveal the source and mark it for re-render on cursor exit
        ;; (see `org-latex-to-svg--on-modify' / `--close-overlay').
        (overlay-put ov 'modification-hooks
                     (list #'org-latex-to-svg--on-modify))
        (setq org-latex-to-svg--rendered-appearance (latex-to-svg-appearance))
        ov))))

;;;; Reveal on cursor entry

(defvar-local org-latex-to-svg--last-point nil
  "Marker at point after the previous command (for cursor reveal tracking).
Since point doesn't move between commands, this is the position point had
*before* the current command — so we can close the preview it left, without
relying on a tracked overlay reference that can go stale.")

(defun org-latex-to-svg--on-modify (ov after &rest _)
  "Modification hook for an image preview OV: reveal its source, flag it.
When the covered text changes (AFTER the edit), drop the image so the
source shows and mark the overlay `org-latex-to-svg-modified' so leaving
it re-renders (see `org-latex-to-svg--close-overlay')."
  (when after
    (overlay-put ov 'org-latex-to-svg-modified t)
    (overlay-put ov 'display nil)))

(defun org-latex-to-svg--revealable-overlay-at (pos)
  "Return this package's preview overlay covering POS, or nil.
Both image previews (`org-latex-to-svg-image') and `\\eqref' / `\\ref'
text previews (`org-latex-to-svg-ref') qualify: moving point into either
reveals its LaTeX source so it can be edited (see
`org-latex-to-svg--open-overlay')."
  (seq-find (lambda (o) (or (overlay-get o 'org-latex-to-svg-image)
                            (overlay-get o 'org-latex-to-svg-ref)))
            (overlays-at pos)))

(defun org-latex-to-svg--open-overlay (ov)
  "Reveal OV's LaTeX source by hiding its image / reference text."
  (overlay-put ov 'display nil))

(defun org-latex-to-svg--close-overlay (ov)
  "Re-show OV's preview, or re-render it if its source was edited while open.
An unedited image preview restores its cached image and an unedited
reference restores its `(N)' / `N' text; an edited preview (its LaTeX
source changed) is re-rendered so images retypeset and references pick up
a new label / number."
  (when (overlay-buffer ov)
    (cond
     ((overlay-get ov 'org-latex-to-svg-modified)
      (overlay-put ov 'org-latex-to-svg-modified nil)
      (org-latex-to-svg--rerender-overlay ov))
     ((overlay-get ov 'org-latex-to-svg-image)
      (overlay-put ov 'display (overlay-get ov 'org-latex-to-svg-image)))
     ((overlay-get ov 'org-latex-to-svg-ref)
      (overlay-put ov 'display (overlay-get ov 'org-latex-to-svg-ref-display))))))

(defun org-latex-to-svg--rerender-overlay (ov)
  "Re-render the math element under OV after an edit; else drop OV."
  (when-let* ((start (overlay-start ov)))
    (let ((el (save-excursion (goto-char start) (org-element-context))))
      (if (and el (memq (org-element-type el) org-latex-to-svg--element-types))
          (progn
            (org-latex-to-svg--render-element el)
            (org-latex-to-svg--schedule-reconcile))
        (delete-overlay ov)))))

(defun org-latex-to-svg--render-left (from to)
  "Render the math element FROM was inside, once TO has left its span.
This is how newly typed math appears: a complete, not-yet-rendered
element is compiled the moment the cursor leaves it (never while still
inside, so half-typed math is not compiled).  A `latex-fragment' /
`latex-environment' that `org-element-context' doesn't recognise (e.g. an
unfinished environment) yields nothing until it is closed and left."
  (when-let* ((el (save-excursion (goto-char from) (org-element-context))))
    (when (memq (org-element-type el) org-latex-to-svg--element-types)
      (let* ((bounds (org-latex-to-svg--element-bounds el))
             (b (car bounds)) (e (cdr bounds)))
        (when (and (or (< to b) (> to e))
                   (not (org-latex-to-svg--overlays-in b e)))
          (org-latex-to-svg--render-element el)
          ;; A new equation can shift every number below it.
          (org-latex-to-svg--schedule-reconcile))))))

(defun org-latex-to-svg--handle-cursor ()
  "Reveal the preview point moved into, re-hide the one it left, and render
any newly finished equation the cursor just left.
On `post-command-hook' while the mode is on.  Closes the overlay at the
*previous* point (`org-latex-to-svg--last-point') rather than a tracked
reference, so it stays correct across overlay-to-overlay jumps and edits.
A reference reached by *mouse* is not revealed: a click there is a jump
\(`mouse-1' -> `org-latex-to-svg-goto-reference'), not an edit, so its
number stays shown; keyboard entry still reveals it for label editing."
  (when org-latex-to-svg-mode
    (let ((last (and org-latex-to-svg--last-point
                     (marker-position org-latex-to-svg--last-point))))
      ;; Render an equation the cursor just left (event-driven, no idle timer).
      (when (and last (/= last (point)))
        (org-latex-to-svg--render-left last (point)))
      (let* ((prev (and last (org-latex-to-svg--revealable-overlay-at last)))
             (cur (org-latex-to-svg--revealable-overlay-at (point))))
      (when (and prev (not (eq prev cur)))
        (org-latex-to-svg--close-overlay prev))
      (when (and cur (not (eq cur prev))
                 (not (and (overlay-get cur 'org-latex-to-svg-ref)
                           (mouse-event-p last-command-event))))
        (org-latex-to-svg--open-overlay cur))
      (unless org-latex-to-svg--last-point
        (setq org-latex-to-svg--last-point (make-marker)))
      (set-marker org-latex-to-svg--last-point (point))))))

(defun org-latex-to-svg--heal-modified ()
  "Re-render previews that were edited and then left by point.
Backstop for the cursor state machine (e.g. a fragment never entered via
cursor, or an overlay that evaporated mid-edit): any preview flagged
`org-latex-to-svg-modified' whose span no longer contains point is
re-rendered now.  A preview still under point is left revealed (you are
still editing it)."
  (dolist (ov (org-latex-to-svg--overlays-in (point-min) (point-max)))
    (when (and (overlay-get ov 'org-latex-to-svg-modified)
               (or (< (point) (overlay-start ov))
                   (> (point) (overlay-end ov))))
      (overlay-put ov 'org-latex-to-svg-modified nil)
      (org-latex-to-svg--rerender-overlay ov))))

(defun org-latex-to-svg--set-reference-overlay (beg end label num display)
  "Overlay BEG..END with plain-text DISPLAY for a reference to LABEL.
NUM is the resolved number, recorded in `org-latex-to-svg-ref-num' so a
reconcile can detect when the target renumbered.
Unlike `org-latex-to-svg--set-overlay' this draws ordinary buffer text
\(so it matches the prose font and needs no theme / zoom refresh) rather
than a LaTeX image, and makes the span click-to-jump (`mouse-1' / `RET')
to the equation defining LABEL.  Like an image preview it reveals its
source on cursor entry / edit and re-renders on leave (see
`org-latex-to-svg--close-overlay'); DISPLAY is stashed in
`org-latex-to-svg-ref-display' so an unedited leave can restore it."
  (let ((b (if (markerp beg) (marker-position beg) beg))
        (e (if (markerp end) (marker-position end) end)))
    (when (and b e (< b e) (<= (point-min) b) (<= e (point-max)))
      (org-latex-to-svg--clear-region b e)
      (let ((ov (make-overlay b e)))
        (overlay-put ov 'org-latex-to-svg t)
        (overlay-put ov 'org-latex-to-svg-ref label)
        (overlay-put ov 'org-latex-to-svg-ref-num num)
        (overlay-put ov 'org-latex-to-svg-ref-display display)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'display display)
        (overlay-put ov 'keymap org-latex-to-svg--reference-keymap)
        (overlay-put ov 'mouse-face 'highlight)
        (overlay-put ov 'help-echo
                     (format "mouse-1: jump to the equation labelled %s" label))
        ;; On edit: reveal the source and mark for re-render on cursor exit
        ;; (shared with image previews; see `org-latex-to-svg--on-modify' /
        ;; `--close-overlay').
        (overlay-put ov 'modification-hooks
                     (list #'org-latex-to-svg--on-modify))
        ov))))

;;;; Numbering

(defun org-latex-to-svg--environment-name (value)
  "Return the LaTeX environment name at the start of source VALUE, or nil.
VALUE is an element's verbatim `:value'; matches a leading
`\\begin{NAME}' (fragments, which have no such prefix, return nil)."
  (and (string-match "\\`[ \t\n]*\\\\begin{\\([^}]+\\)}" value)
       (match-string 1 value)))

(defun org-latex-to-svg--count-multi-rows (value env)
  "Count numbered rows in multi-equation environment source VALUE named ENV.
Strips the outer environment and every nested environment (whose
`\\\\' are not equation separators) in a scratch buffer, counts the
remaining `\\\\' row breaks, then subtracts `\\nonumber' / `\\notag' /
`\\tag' suppressed rows.  Never returns below zero."
  (with-temp-buffer
    (insert value)
    ;; Drop the outer \begin{ENV} … \end{ENV} wrapper.
    (goto-char (point-min))
    (when (re-search-forward (concat "\\\\begin{" (regexp-quote env) "}") nil t)
      (delete-region (point-min) (point)))
    (goto-char (point-max))
    (when (re-search-backward (concat "\\\\end{" (regexp-quote env) "}") nil t)
      (delete-region (match-beginning 0) (point-max)))
    ;; Remove nested environments (matrix, cases, array, aligned, …): repeatedly
    ;; delete the nearest \begin…\end pair, innermost first.
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
    ;; rows = 1 + hard row breaks; minus suppressed rows.
    (let ((rows 1) (suppressed 0))
      (goto-char (point-min))
      (while (re-search-forward "\\\\\\\\" nil t) (cl-incf rows))
      (goto-char (point-min))
      (while (re-search-forward "\\\\nonumber\\|\\\\notag\\|\\\\tag{" nil t)
        (cl-incf suppressed))
      (max 0 (- rows suppressed)))))

(defun org-latex-to-svg--count-numbered-equations (value)
  "Return how many numbered equations the environment source VALUE consumes.
Unknown / non-numbered environments (and starred forms) consume 0."
  (let ((env (org-latex-to-svg--environment-name value)))
    (cond
     ((member env org-latex-to-svg--numbered-environments-single)
      ;; A lone \nonumber / \notag / \tag suppresses the single number.
      (if (string-match-p "\\\\nonumber\\|\\\\notag\\|\\\\tag{" value) 0 1))
     ((member env org-latex-to-svg--numbered-environments-multi)
      (org-latex-to-svg--count-multi-rows value env))
     (t 0))))

(defun org-latex-to-svg--labels-in (text)
  "Return the list of `\\label' names in TEXT, in document order."
  (let ((names nil) (start 0))
    (while (string-match "\\\\label{\\([^}]+\\)}" text start)
      (push (match-string 1 text) names)
      (setq start (match-end 0)))
    (nreverse names)))

(defun org-latex-to-svg--multi-row-labels (value env offset)
  "Return an alist of (LABEL . NUMBER) for multi-equation source VALUE.
ENV is the environment name; OFFSET the counter before the block, so the
first numbered row is OFFSET+1.  Rows are split on top-level `\\\\' (breaks
inside nested environments don't split); a `\\nonumber' / `\\notag' /
`\\tag' row is unnumbered and does not advance the counter."
  (with-temp-buffer
    (insert value)
    ;; Strip the outer \begin{ENV} … \end{ENV} wrapper.
    (goto-char (point-min))
    (when (re-search-forward (concat "\\\\begin{" (regexp-quote env) "}") nil t)
      (delete-region (point-min) (point)))
    (goto-char (point-max))
    (when (re-search-backward (concat "\\\\end{" (regexp-quote env) "}") nil t)
      (delete-region (match-beginning 0) (point-max)))
    ;; Split into rows on top-level `\\', tracking nested-environment depth.
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
      ;; Assign each numbered row's number to the labels it carries.
      (let ((num (1+ offset)) (out nil))
        (dolist (row rows)
          (if (string-match-p "\\\\nonumber\\|\\\\notag\\|\\\\tag{" row)
              nil
            (dolist (name (org-latex-to-svg--labels-in row))
              (push (cons name num) out))
            (cl-incf num)))
        (nreverse out)))))

(defun org-latex-to-svg--scan-numbering ()
  "Scan the widened buffer; return the cons (OFFSETS . LABELS).
OFFSETS maps a numbered environment's `:begin' to its counter offset
\(preceding numbered equations), so prepending
`\\setcounter{equation}{OFFSET}' makes LaTeX print the block's numbers.
LABELS maps a `\\label' name (string) to its resolved equation number,
for `\\eqref' / `\\ref'.  One document-order pass; only
`latex-environment' elements can be numbered."
  (let ((offsets (make-hash-table :test 'eql))
        (labels (make-hash-table :test 'equal))
        (offset 0))
    (save-restriction
      (widen)
      (dolist (el (org-element-map (org-element-parse-buffer)
                      'latex-environment #'identity))
        (let* ((value (org-element-property :value el))
               (env (org-latex-to-svg--environment-name value)))
          (when (member env org-latex-to-svg--numbered-environments-all)
            (puthash (org-element-property :begin el) offset offsets)
            (let ((count (org-latex-to-svg--count-numbered-equations value)))
              (cond
               ((member env org-latex-to-svg--numbered-environments-single)
                (when (= count 1)
                  (dolist (name (org-latex-to-svg--labels-in value))
                    (puthash name (1+ offset) labels))))
               ((member env org-latex-to-svg--numbered-environments-multi)
                (dolist (pair (org-latex-to-svg--multi-row-labels value env offset))
                  (puthash (car pair) (cdr pair) labels))))
              (cl-incf offset count))))))
    (cons offsets labels)))

(defun org-latex-to-svg--numbering-table ()
  "Return only the `:begin' -> offset hash.
See `org-latex-to-svg--scan-numbering' for the full scan."
  (car (org-latex-to-svg--scan-numbering)))

(defun org-latex-to-svg--maybe-table ()
  "Return a fresh (OFFSETS . LABELS) scan when numbering is enabled, else nil.
Also installs `latex-to-svg-metadata-prefix' so numbered compiles record
their final counter into the engine's `.eld' sidecar."
  (when org-latex-to-svg-number-equations
    (setq latex-to-svg-metadata-prefix org-latex-to-svg--metadata-prefix)
    (org-latex-to-svg--scan-numbering)))

(defun org-latex-to-svg--reference-parse (source)
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

(defun org-latex-to-svg--reference-display (source labels)
  "If SOURCE is a resolvable `\\eqref' / `\\ref' fragment, return its display text.
`\\eqref' -> \"(N)\", `\\ref' -> \"N\" — plain buffer text, not LaTeX — or
nil when SOURCE isn't such a reference or the label is unknown.  See
`org-latex-to-svg--reference-parse' for the accepted forms."
  (when-let* ((parsed (org-latex-to-svg--reference-parse source))
              (num (gethash (cdr parsed) labels)))
    (if (equal (car parsed) "eqref") (format "(%d)" num) (number-to-string num))))

(defun org-latex-to-svg--label-position (label)
  "Return the `:begin' of the math element defining LABEL, or nil.
Searches the widened buffer for `\\label{LABEL}' inside a math element."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (let ((needle (format "\\label{%s}" label)) pos)
        (while (and (not pos) (search-forward needle nil t))
          (let ((el (save-excursion (goto-char (match-beginning 0))
                                    (org-element-context))))
            (when (memq (org-element-type el) org-latex-to-svg--element-types)
              (setq pos (org-element-property :begin el)))))
        pos))))

(defun org-latex-to-svg--setcounter-value (k source)
  "Wrap SOURCE for numbered rendering starting at counter K.
Prefixes `\\setcounter{equation}{K}' (so LaTeX prints the right numbers,
and K folds into the engine hash) and appends a `\\typeout' probe emitting
the block's final counter — captured into the `.eld' sidecar as FINAL
\(see `latex-to-svg-metadata').  The probe has no visual effect."
  (format "\\setcounter{equation}{%d}%%\n%s\\typeout{%s\\arabic{equation}}%%\n"
          k source org-latex-to-svg--metadata-prefix))

(defun org-latex-to-svg--numbered-value (el source table)
  "Return the exact engine string for EL: SOURCE, adjusted for numbering.
TABLE is a (OFFSETS . LABELS) scan.  A numbered environment (its `:begin'
in OFFSETS) gets `org-latex-to-svg--setcounter-value'; otherwise SOURCE is
returned unchanged.  `\\eqref' / `\\ref' fragments are handled separately
\(drawn as buffer text, not LaTeX)."
  (let ((k (and (car-safe table)
                (gethash (org-element-property :begin el) (car-safe table)))))
    (if k (org-latex-to-svg--setcounter-value k source) source)))

;;;; Rendering

(defun org-latex-to-svg--place (buffer beg end value &optional source enums-fallback display-p)
  "Ensure BUFFER's BEG..END shows the current image for render VALUE.
VALUE is the exact engine input (numbered environments carry their
`\\setcounter' prefix); SOURCE is the plain LaTeX for `help-echo'.
ENUMS-FALLBACK, when non-nil, marks VALUE as a numbered equation: its
`car' (INITIAL = K+1) is passed to the engine as `:metadata' and the cons
is the number-range fallback (see `org-latex-to-svg--set-overlay').
DISPLAY-P selects the inline / display size multiplier (`:rescale-by').
Overlays immediately on a cache hit, else schedules an async compile and
overlays when it finishes.  BEG / END should be markers."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((image (latex-to-svg
                    value
                    :rescale-by (org-latex-to-svg--rescale-for display-p)
                    :metadata (car enums-fallback)
                    :callback (lambda ()
                                (org-latex-to-svg--place
                                 buffer beg end value source enums-fallback display-p)))))
        (when image
          (org-latex-to-svg--set-overlay beg end value image source enums-fallback display-p))))))

(defun org-latex-to-svg--render-numbered (el k)
  "Render numbered environment EL starting at counter K.
Passes INITIAL = K+1 to the engine as `:metadata' and a heuristic
\(INITIAL . FINAL) fallback so the overlay records its number range even
before ground-truth `.eld' metadata is available."
  (let* ((bounds (org-latex-to-svg--element-bounds el))
         (source (org-element-property :value el))
         (value (org-latex-to-svg--setcounter-value k source))
         (heuristic (org-latex-to-svg--count-numbered-equations source)))
    (org-latex-to-svg--place (current-buffer)
                             (copy-marker (car bounds))
                             (copy-marker (cdr bounds))
                             value source (cons (1+ k) (+ k heuristic))
                             (org-latex-to-svg--display-p source))))

(defun org-latex-to-svg--render-element (el &optional table)
  "Render math element EL in the current buffer.
TABLE is a (OFFSETS . LABELS) numbering scan; when omitted one is built
on demand so single-element renders still number / resolve correctly.
A resolvable `\\eqref' / `\\ref' is drawn as clickable buffer text, a
numbered environment via `org-latex-to-svg--render-numbered'; everything
else is typeset verbatim by the engine."
  (let* ((bounds (org-latex-to-svg--element-bounds el))
         (source (org-element-property :value el))
         (table (or table (org-latex-to-svg--maybe-table)))
         (offsets (car-safe table))
         (labels (cdr-safe table))
         (parsed (and labels (eq (org-element-type el) 'latex-fragment)
                      (org-latex-to-svg--reference-parse source)))
         (refnum (and parsed (gethash (cdr parsed) labels)))
         (k (and offsets (gethash (org-element-property :begin el) offsets))))
    (cond
     (refnum
      (org-latex-to-svg--set-reference-overlay
       (copy-marker (car bounds)) (copy-marker (cdr bounds))
       (cdr parsed) refnum
       (propertize (if (equal (car parsed) "eqref")
                       (format "(%d)" refnum) (number-to-string refnum))
                   'face 'org-latex-to-svg-reference)))
     (k (org-latex-to-svg--render-numbered el k))
     (t (org-latex-to-svg--place (current-buffer)
                                 (copy-marker (car bounds))
                                 (copy-marker (cdr bounds))
                                 source source nil
                                 (org-latex-to-svg--display-p source))))))

(defun org-latex-to-svg--render-region (beg end)
  "Render every math element overlapping BEG..END in the current buffer."
  (let ((table (org-latex-to-svg--maybe-table)))
    (dolist (el (org-latex-to-svg--elements beg end))
      (org-latex-to-svg--render-element el table))))

(defun org-latex-to-svg--numbered-overlay-at (pos)
  "Return the numbered-equation overlay covering POS (one with enums), or nil."
  (seq-find (lambda (o) (overlay-get o 'org-latex-to-svg-enums))
            (overlays-in pos (min (point-max) (1+ pos)))))

(defun org-latex-to-svg--refresh-references (labels)
  "Update every reference preview whose resolved number changed under LABELS.
Rewrites the overlay's displayed `(N)' / `N' in place (no LaTeX)."
  (dolist (ov (org-latex-to-svg--overlays-in (point-min) (point-max)))
    (when-let* ((name (overlay-get ov 'org-latex-to-svg-ref))
                (want (gethash name labels)))
      (unless (eql want (overlay-get ov 'org-latex-to-svg-ref-num))
        (when-let* ((parsed (org-latex-to-svg--reference-parse
                             (buffer-substring-no-properties
                              (overlay-start ov) (overlay-end ov)))))
          (let ((disp (propertize (if (equal (car parsed) "eqref")
                                      (format "(%d)" want) (number-to-string want))
                                  'face 'org-latex-to-svg-reference)))
            (overlay-put ov 'org-latex-to-svg-ref-display disp)
            ;; Don't clobber an overlay revealed for editing (display nil).
            (when (overlay-get ov 'display)
              (overlay-put ov 'display disp))
            (overlay-put ov 'org-latex-to-svg-ref-num want)))))))

(defun org-latex-to-svg--reconcile (&optional buffer)
  "Recompute equation numbers and re-render previews whose number changed.
Threads the `equation' counter over the numbered environments in document
order, taking each block's consumed count from its overlay's ground-truth
`.eld' metadata when available, else the Elisp heuristic.  A block whose
preview no longer shows the right first number (INITIAL != K+1) is
re-rendered at the corrected K; reference previews are refreshed too.
Only spans that still carry an overlay are touched, so a cleared /
being-edited equation keeps revealing its source.  No-op unless the mode
and numbering are on."
  (with-current-buffer (or buffer (current-buffer))
    (when (and (bound-and-true-p org-latex-to-svg-mode)
               org-latex-to-svg-number-equations)
      (setq latex-to-svg-metadata-prefix org-latex-to-svg--metadata-prefix)
      (save-restriction
        (widen)
        (let ((k 0))
          (dolist (el (org-element-map (org-element-parse-buffer)
                          'latex-environment #'identity))
            (let ((env (org-latex-to-svg--environment-name
                        (org-element-property :value el))))
              (when (member env org-latex-to-svg--numbered-environments-all)
                (let* ((begin (org-element-property :begin el))
                       (ov (org-latex-to-svg--numbered-overlay-at begin))
                       (enums (and ov (overlay-get ov 'org-latex-to-svg-enums)))
                       (consumed (if enums
                                     (- (cdr enums) (car enums) -1)
                                   (org-latex-to-svg--count-numbered-equations
                                    (org-element-property :value el)))))
                  (when (and ov
                             ;; Skip a preview revealed for editing (point in it).
                             (overlay-get ov 'display)
                             (not (equal (car enums) (1+ k))))
                    (org-latex-to-svg--render-numbered el k))
                  (setq k (+ k (max 0 consumed)))))))
          (org-latex-to-svg--refresh-references
           (cdr (org-latex-to-svg--scan-numbering))))))))

(defvar-local org-latex-to-svg--reconcile-timer nil
  "Pending debounced reconcile timer for this buffer.")

(defun org-latex-to-svg--schedule-reconcile (&rest _)
  "Debounce a numbering reconcile of the current buffer (see `--reconcile').
Hooked to `after-change-functions' (and fired when ground truth corrects a
heuristic guess).  A backstop that re-renders any preview edited and left
\(`--heal-modified') and renumbers downstream; the initial render of newly
typed math is handled event-driven, on cursor leave (`--render-left'), not
here.  No-op unless the mode and the idle option are on."
  (when (and (bound-and-true-p org-latex-to-svg-mode)
             org-latex-to-svg-reconcile-idle)
    (when (timerp org-latex-to-svg--reconcile-timer)
      (cancel-timer org-latex-to-svg--reconcile-timer))
    (let ((buf (current-buffer)))
      (setq org-latex-to-svg--reconcile-timer
            (run-with-idle-timer
             org-latex-to-svg-reconcile-idle nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq org-latex-to-svg--reconcile-timer nil)
                   (when (bound-and-true-p org-latex-to-svg-mode)
                     (org-latex-to-svg--heal-modified))
                   (org-latex-to-svg--reconcile buf)))))))))

;;;; Refresh (theme / font tracking)

(defun org-latex-to-svg--refresh-buffer (buffer)
  "Re-tint / re-scale BUFFER's previews for the current appearance.
Re-fetches each overlay's image from the engine (a cache hit at the
new color / scale — no LaTeX) and updates the `display' property."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (ov (org-latex-to-svg--overlays-in (point-min) (point-max)))
        (when-let* ((value (overlay-get ov 'org-latex-to-svg-value))
                    (image (latex-to-svg
                            value :rescale-by
                            (org-latex-to-svg--rescale-for
                             (overlay-get ov 'org-latex-to-svg-display-math)))))
          (overlay-put ov 'org-latex-to-svg-image image)
          ;; Don't clobber an overlay revealed for editing (display nil).
          (when (overlay-get ov 'display)
            (overlay-put ov 'display image))))
      (setq org-latex-to-svg--rendered-appearance (latex-to-svg-appearance)))))

;;;###autoload
(defun org-latex-to-svg-refresh (&optional buffer)
  "Re-render previews in BUFFER (default current) for the current theme and font.
Previews also refresh lazily on theme, buffer-display, and zoom
changes; this forces it now (and after a pure global font-size change)."
  (interactive)
  (org-latex-to-svg--refresh-buffer (or buffer (current-buffer))))

(defun org-latex-to-svg--present-p ()
  "Return non-nil if the current buffer has preview overlays."
  (and org-latex-to-svg-mode
       (org-latex-to-svg--overlays-in (point-min) (point-max))))

(defun org-latex-to-svg--refresh-if-changed ()
  "Refresh the current buffer's previews if its appearance changed."
  (when (and (org-latex-to-svg--present-p)
             (not (equal (latex-to-svg-appearance)
                         org-latex-to-svg--rendered-appearance)))
    (org-latex-to-svg-refresh (current-buffer))))

(defun org-latex-to-svg--maybe-refresh (&rest _)
  "Schedule a lazy appearance-changed refresh of the current buffer.
Hooked to `text-scale-mode-hook' and `window-buffer-change-functions'
\(a buffer-local zoom, or a buffer shown after its appearance changed
while hidden).  Deferred to idle so a freshly applied text scale is in
effect; a no-op when the buffer has no previews."
  (when org-latex-to-svg-mode
    (let ((buf (current-buffer)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (org-latex-to-svg--refresh-if-changed))))))))

(defun org-latex-to-svg--on-theme-change (&rest _)
  "Refresh every preview buffer whose appearance changed after a theme switch.
A theme is global, so unlike zoom this visits all mode-enabled buffers
rather than only the current one.  Deferred to idle so the new palette
is fully applied."
  (run-at-time
   0 nil
   (lambda ()
     (dolist (buf (buffer-list))
       (when (buffer-local-value 'org-latex-to-svg-mode buf)
         (with-current-buffer buf
           (org-latex-to-svg--refresh-if-changed)))))))

(add-hook 'enable-theme-functions #'org-latex-to-svg--on-theme-change)
(add-hook 'text-scale-mode-hook #'org-latex-to-svg--maybe-refresh)
(add-hook 'window-buffer-change-functions #'org-latex-to-svg--maybe-refresh)

;;;; Command and mode

(defun org-latex-to-svg--ref-overlay-at (pos)
  "Return this package's reference overlay covering POS, or nil."
  (seq-find (lambda (o) (overlay-get o 'org-latex-to-svg-ref))
            (overlays-in (max (point-min) (1- pos))
                         (min (point-max) (1+ pos)))))

(defun org-latex-to-svg-goto-reference (&optional event)
  "Jump to the equation defining the label of the reference preview at point.
Bound in `\\eqref' / `\\ref' preview overlays to `mouse-1' and `RET'; EVENT
is the triggering input event when invoked with the mouse."
  (interactive (list last-command-event))
  (when (and (consp event) (eventp event))
    (let ((posn (event-start event)))
      (when (windowp (posn-window posn)) (select-window (posn-window posn)))
      (when (numberp (posn-point posn)) (goto-char (posn-point posn)))))
  (let* ((ov (org-latex-to-svg--ref-overlay-at (point)))
         (label (and ov (overlay-get ov 'org-latex-to-svg-ref)))
         (pos (and label (org-latex-to-svg--label-position label))))
    (cond
     ((null label) (user-error "No equation reference here"))
     ((null pos) (user-error "Cannot find an equation labelled %s" label))
     (t (push-mark)
        (goto-char pos)
        (when (fboundp 'org-fold-show-context) (org-fold-show-context))
        (when (get-buffer-window (current-buffer)) (recenter))
        (message "Jumped to \\label{%s}" label)))))

(defvar org-latex-to-svg--reference-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'org-latex-to-svg-goto-reference)
    (define-key map (kbd "RET") #'org-latex-to-svg-goto-reference)
    map)
  "Keymap installed on `\\eqref' / `\\ref' preview overlays for click-to-jump.")

;;;###autoload
(defun org-latex-to-svg-clear (&optional beg end)
  "Clear previews in BEG..END, revealing the LaTeX source.
Interactively acts on the active region, or the whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (point-min) (point-max))))
  (org-latex-to-svg--clear-region (or beg (point-min)) (or end (point-max))))

;;;###autoload
(defun org-latex-to-svg-regenerate (&optional beg end)
  "Force a fresh recompile of previews in BEG..END.

Deletes each equation's cached SVG (via `latex-to-svg-invalidate') and
clears its overlay, then re-renders — bypassing the content-addressed
cache.  Use this to recover from a stale or corrupt cached image.
Interactively acts on the active region, or the whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (point-min) (point-max))))
  (let ((beg (or beg (point-min)))
        (end (or end (point-max)))
        (table (org-latex-to-svg--maybe-table)))
    (dolist (el (org-latex-to-svg--elements beg end))
      ;; Invalidate the *rendered* string (with any `\setcounter' prefix), so
      ;; the hash we drop matches the one actually cached.
      (latex-to-svg-invalidate
       (org-latex-to-svg--numbered-value
        el (org-element-property :value el) table)))
    (org-latex-to-svg--clear-region beg end)
    (org-latex-to-svg--render-region beg end)))

;;;###autoload
(defun org-latex-to-svg (&optional arg)
  "Preview Org LaTeX math as SVG images.

With no prefix ARG: toggle the fragment at point; or, with an active
region, render that region; or, failing both, render the whole buffer.

With a `\\[universal-argument]' prefix, re-render the whole buffer (clear
then render) — rebuilds overlays from cache, fixing a stale display.

With a `\\[universal-argument] \\[universal-argument]' prefix, regenerate
the whole buffer: a fresh recompile bypassing the cache (see
`org-latex-to-svg-regenerate').

To clear previews without re-rendering, use `org-latex-to-svg-clear' or
turn off `org-latex-to-svg-mode'."
  (interactive "P")
  (cond
   ((equal arg '(16))
    (org-latex-to-svg-regenerate (point-min) (point-max))
    (message "Regenerated LaTeX previews"))
   ((equal arg '(4))
    (org-latex-to-svg--clear-region (point-min) (point-max))
    (org-latex-to-svg--render-region (point-min) (point-max))
    (message "Re-rendered LaTeX previews"))
   ((use-region-p)
    (org-latex-to-svg--render-region (region-beginning) (region-end))
    ;; A rendered region may have added / removed a number; correct the rest.
    (org-latex-to-svg--reconcile)
    (deactivate-mark))
   ((org-latex-to-svg--context)
    (let* ((el (org-latex-to-svg--context))
           (b (org-element-property :begin el))
           (e (org-element-property :end el)))
      (if (org-latex-to-svg--overlays-in b e)
          (org-latex-to-svg--clear-region b e)
        (org-latex-to-svg--render-element el)
        ;; Re-rendering an edited equation can shift every number below it.
        (org-latex-to-svg--reconcile))))
   (t
    (org-latex-to-svg--render-region (point-min) (point-max))
    (org-latex-to-svg--reconcile))))

(defvar org-latex-to-svg-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Shadow Org's classic `org-latex-preview' on the same key while the mode
    ;; is on; the classic command is unshadowed again when the mode is off.
    (define-key map (kbd "C-c C-x C-l") #'org-latex-to-svg)
    map)
  "Keymap for `org-latex-to-svg-mode'.")

;;;###autoload
(define-minor-mode org-latex-to-svg-mode
  "Minor mode previewing Org LaTeX math as SVG images via `latex-to-svg'.

When enabled, all math fragments and environments in the buffer are
rendered; disabling clears them.  See `org-latex-to-svg' for the
interactive command bound to \\[org-latex-to-svg]."
  :lighter " L2S"
  :keymap org-latex-to-svg-mode-map
  (if org-latex-to-svg-mode
      (if (derived-mode-p 'org-mode)
          (progn
            ;; Auto-heal equation numbers a short while after edits.
            (add-hook 'after-change-functions
                      #'org-latex-to-svg--schedule-reconcile nil t)
            ;; Reveal the source of the preview point moves into.
            (add-hook 'post-command-hook
                      #'org-latex-to-svg--handle-cursor nil t)
            ;; Take over from any built-in Org LaTeX previews in the buffer.
            (org-latex-to-svg--clear-native (point-min) (point-max))
            (org-latex-to-svg--render-region (point-min) (point-max)))
        (setq org-latex-to-svg-mode nil)
        (user-error "`org-latex-to-svg-mode' only works in Org buffers"))
    (remove-hook 'after-change-functions
                 #'org-latex-to-svg--schedule-reconcile t)
    (remove-hook 'post-command-hook #'org-latex-to-svg--handle-cursor t)
    (when (markerp org-latex-to-svg--last-point)
      (set-marker org-latex-to-svg--last-point nil))
    (setq org-latex-to-svg--last-point nil)
    (when (timerp org-latex-to-svg--reconcile-timer)
      (cancel-timer org-latex-to-svg--reconcile-timer)
      (setq org-latex-to-svg--reconcile-timer nil))
    (org-latex-to-svg--clear-region (point-min) (point-max))
    (setq org-latex-to-svg--rendered-appearance nil)))

(provide 'org-latex-to-svg)

;;; org-latex-to-svg.el ends here
