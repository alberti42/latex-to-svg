;;; org-latex-to-svg.el --- Preview Org LaTeX math as SVG via latex-to-svg -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; URL: https://github.com/alberti42/org-latex-to-svg
;; Version: 0.2.1
;; Package-Requires: ((emacs "29.1") (latex-to-svg "0.2.1"))
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
;; Numbered display environments (`equation', `align', …) get their real
;; document-wide number via `org-latex-to-svg-number-equations' (on by
;; default): the count of preceding numbered equations is computed in Elisp
;; and baked in as a `\\setcounter' prefix, so the number is part of the
;; engine's content hash (see NUMBERING.md).  `\\eqref' / `\\ref' are resolved
;; against a `\\label' -> number map built in the same scan and rendered as
;; `$(N)$' / `$N$'; their previews are click-to-jump (mouse-1 / RET) to the
;; equation defining the label.  Reveal-on-cursor-enter (editing without first
;; clearing) is still a later milestone.

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
the numbered equations that precede the block (see NUMBERING.md); the
number is part of the engine's content hash, so a block re-renders only
when its number actually changes.

When nil, every element renders verbatim (no numbering)."
  :type 'boolean
  :group 'org-latex-to-svg)

(defconst org-latex-to-svg--element-types '(latex-fragment latex-environment)
  "Org element types rendered as equations.")

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

(defun org-latex-to-svg--set-overlay (beg end value image &optional source ref-label)
  "Overlay BEG..END (positions or markers) with IMAGE, keyed to render VALUE.
VALUE is the exact string handed to the engine (a numbered environment
carries its `\\setcounter' prefix) so a cache refresh re-fetches the same
hash; SOURCE, if given, is the human-readable LaTeX shown in `help-echo'.
REF-LABEL, when non-nil, marks this as an `\\eqref' / `\\ref' preview for
the named label and makes the overlay click-to-jump to that equation.
Replaces any existing preview overlay in the span.  The overlay clears
itself when the underlying text is edited, revealing the source."
  (let ((b (if (markerp beg) (marker-position beg) beg))
        (e (if (markerp end) (marker-position end) end)))
    (when (and b e (< b e) (<= (point-min) b) (<= e (point-max)))
      (org-latex-to-svg--clear-region b e)
      (let ((ov (make-overlay b e)))
        (overlay-put ov 'org-latex-to-svg t)
        (overlay-put ov 'org-latex-to-svg-value value)
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'help-echo (or source value))
        (overlay-put ov 'display image)
        ;; An \eqref / \ref preview jumps to its target equation on click.
        (when ref-label
          (overlay-put ov 'org-latex-to-svg-ref ref-label)
          (overlay-put ov 'keymap org-latex-to-svg--reference-keymap)
          (overlay-put ov 'mouse-face 'highlight)
          (overlay-put ov 'help-echo
                       (format "mouse-1: jump to the equation labelled %s"
                               ref-label)))
        ;; Reveal the source when the fragment is edited (mirrors Org's own
        ;; preview overlays): drop the image on any modification touching it.
        (overlay-put ov 'modification-hooks
                     (list (lambda (o &rest _) (delete-overlay o))))
        (setq org-latex-to-svg--rendered-appearance (latex-to-svg-appearance))
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
  "Return a fresh (OFFSETS . LABELS) scan when numbering is enabled, else nil."
  (and org-latex-to-svg-number-equations
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

(defun org-latex-to-svg--reference-value (source labels)
  "If SOURCE is a resolvable `\\eqref' / `\\ref' fragment, return its rendered form.
Looks the label up in LABELS (name -> number) and returns a `$(N)$'
\(eqref) or `$N$' (ref) string, or nil when SOURCE isn't such a reference
or the label is unknown (leave it verbatim then)."
  (when-let* ((parsed (org-latex-to-svg--reference-parse source))
              (num (gethash (cdr parsed) labels)))
    (if (equal (car parsed) "eqref") (format "$(%d)$" num) (format "$%d$" num))))

(defun org-latex-to-svg--reference-label (source)
  "Return the label NAME if SOURCE is an `\\eqref' / `\\ref' fragment, else nil."
  (cdr (org-latex-to-svg--reference-parse source)))

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

(defun org-latex-to-svg--numbered-value (el source table)
  "Return the string to render for EL: SOURCE, adjusted for numbering.
TABLE is a (OFFSETS . LABELS) scan.  A numbered environment gets a
`\\setcounter' prefix (folded into the engine hash, so the number is
cached); a resolvable `\\eqref' / `\\ref' fragment becomes `$(N)$' / `$N$';
otherwise SOURCE is returned unchanged."
  (let ((offsets (car-safe table))
        (labels (cdr-safe table)))
    (cond
     ((and offsets (gethash (org-element-property :begin el) offsets))
      (format "\\setcounter{equation}{%d}%%\n%s"
              (gethash (org-element-property :begin el) offsets) source))
     ((and labels
           (eq (org-element-type el) 'latex-fragment)
           (org-latex-to-svg--reference-value source labels)))
     (t source))))

;;;; Rendering

(defun org-latex-to-svg--place (buffer beg end value &optional source ref-label)
  "Ensure BUFFER's BEG..END shows the current image for render VALUE.
VALUE is the exact engine input (numbered environments carry their
`\\setcounter' prefix); SOURCE is the plain LaTeX for `help-echo';
REF-LABEL, when non-nil, makes an `\\eqref' / `\\ref' preview click-to-jump.
Overlays immediately when the engine has the image (cache hit), else
schedules an async compile and overlays when it finishes.  BEG / END
should be markers so the overlay lands on the right span even after
edits.  Tint and scale are read from BUFFER at call time."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((image (latex-to-svg
                    value
                    :callback (lambda ()
                                (org-latex-to-svg--place buffer beg end value source ref-label)))))
        (when image
          (org-latex-to-svg--set-overlay beg end value image source ref-label))))))

(defun org-latex-to-svg--render-element (el &optional table)
  "Render math element EL in the current buffer.
TABLE is a numbering table (see `org-latex-to-svg--numbering-table'); when
omitted one is built on demand so single-element renders still number
correctly.  Pass a shared TABLE when rendering many elements."
  (let* ((bounds (org-latex-to-svg--element-bounds el))
         (source (org-element-property :value el))
         (table (or table (org-latex-to-svg--maybe-table)))
         (value (org-latex-to-svg--numbered-value el source table))
         (ref-label (and (eq (org-element-type el) 'latex-fragment)
                         (not (equal value source))
                         (org-latex-to-svg--reference-label source))))
    (org-latex-to-svg--place (current-buffer)
                             (copy-marker (car bounds))
                             (copy-marker (cdr bounds))
                             value source ref-label)))

(defun org-latex-to-svg--render-region (beg end)
  "Render every math element overlapping BEG..END in the current buffer."
  (let ((table (org-latex-to-svg--maybe-table)))
    (dolist (el (org-latex-to-svg--elements beg end))
      (org-latex-to-svg--render-element el table))))

(defun org-latex-to-svg--renumber-following (pos)
  "Re-render numbered-environment previews starting after POS.
When an edit above changes how many numbers a block consumes, every
numbered equation below shifts; this refreshes them for the current
numbering.  Only spans that already carry a preview overlay are touched
\(so we update what's on screen without previewing cleared equations),
and numbers that didn't actually change are engine cache hits — so the
propagation is cheap and stops costing nothing once the count restabilises.
A no-op when numbering is disabled."
  (when org-latex-to-svg-number-equations
    (let ((table (org-latex-to-svg--scan-numbering)))
      (dolist (el (org-latex-to-svg--elements pos (point-max)))
        (let ((bounds (org-latex-to-svg--element-bounds el))
              (source (org-element-property :value el)))
          (when (and (> (org-element-property :begin el) pos)
                     (org-latex-to-svg--overlays-in (car bounds) (cdr bounds))
                     ;; Only elements whose rendering actually depends on
                     ;; numbering: a numbered env or a resolvable \eqref/\ref.
                     (not (equal source
                                 (org-latex-to-svg--numbered-value el source table))))
            (org-latex-to-svg--render-element el table)))))))

;;;; Refresh (theme / font tracking)

(defun org-latex-to-svg--refresh-buffer (buffer)
  "Re-tint / re-scale BUFFER's previews for the current appearance.
Re-fetches each overlay's image from the engine (a cache hit at the
new color / scale — no LaTeX) and updates the `display' property."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (ov (org-latex-to-svg--overlays-in (point-min) (point-max)))
        (when-let* ((value (overlay-get ov 'org-latex-to-svg-value))
                    (image (latex-to-svg value)))
          (overlay-put ov 'display image)))
      (setq org-latex-to-svg--rendered-appearance (latex-to-svg-appearance)))))

;;;###autoload
(defun org-latex-to-svg-refresh (&optional buffer)
  "Re-render previews in BUFFER (default current) for the current theme and font.
Previews also refresh lazily on theme, buffer-display, and zoom
changes; this forces it now (and after a pure global font-size change).
The pixels-per-point calibration is dropped so it is re-measured."
  (interactive)
  (latex-to-svg-flush-metrics)
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
    (let ((end (region-end)))
      (org-latex-to-svg--render-region (region-beginning) end)
      ;; A rendered region may have added / removed a number; refresh the
      ;; numbered equations below it.
      (org-latex-to-svg--renumber-following end))
    (deactivate-mark))
   ((org-latex-to-svg--context)
    (let* ((el (org-latex-to-svg--context))
           (b (org-element-property :begin el))
           (e (org-element-property :end el)))
      (if (org-latex-to-svg--overlays-in b e)
          (org-latex-to-svg--clear-region b e)
        (org-latex-to-svg--render-element el)
        ;; Re-rendering an edited equation can shift every number below it.
        (org-latex-to-svg--renumber-following e))))
   (t
    (org-latex-to-svg--render-region (point-min) (point-max)))))

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
          (org-latex-to-svg--render-region (point-min) (point-max))
        (setq org-latex-to-svg-mode nil)
        (user-error "`org-latex-to-svg-mode' only works in Org buffers"))
    (org-latex-to-svg--clear-region (point-min) (point-max))
    (setq org-latex-to-svg--rendered-appearance nil)))

(provide 'org-latex-to-svg)

;;; org-latex-to-svg.el ends here
