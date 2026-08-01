;;; org-latex-to-svg.el --- Preview Org LaTeX math as SVG via latex-to-svg -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; URL: https://github.com/alberti42/org-latex-to-svg
;; Version: 0.1.1
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
;; This is v0: previews render on mode-enable and on demand, and an overlay
;; clears (revealing its source) when you edit the fragment under it.
;; Reveal-on-cursor-enter (editing without first clearing) is a later
;; milestone, as is equation numbering / `\\eqref' resolution.

;;; Code:

(require 'latex-to-svg)
(require 'org-element)
(require 'seq)

(defgroup org-latex-to-svg nil
  "Preview Org LaTeX math as SVG images via `latex-to-svg'."
  :group 'org
  :prefix "org-latex-to-svg-")

(defconst org-latex-to-svg--element-types '(latex-fragment latex-environment)
  "Org element types rendered as equations.")

;; Forward declaration: the minor-mode variable is defined by the
;; `define-minor-mode' at the end of the file but referenced by the refresh
;; helpers above it.
(defvar org-latex-to-svg-mode)

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

(defun org-latex-to-svg--set-overlay (beg end value image)
  "Overlay BEG..END (positions or markers) with IMAGE, keyed to source VALUE.
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
        (overlay-put ov 'help-echo value)
        (overlay-put ov 'display image)
        ;; Reveal the source when the fragment is edited (mirrors Org's own
        ;; preview overlays): drop the image on any modification touching it.
        (overlay-put ov 'modification-hooks
                     (list (lambda (o &rest _) (delete-overlay o))))
        (setq org-latex-to-svg--rendered-appearance (latex-to-svg-appearance))
        ov))))

;;;; Rendering

(defun org-latex-to-svg--place (buffer beg end value)
  "Ensure BUFFER's BEG..END shows the current image for source VALUE.
Overlays immediately when the engine has the image (cache hit), else
schedules an async compile and overlays when it finishes.  BEG / END
should be markers so the overlay lands on the right span even after
edits.  Tint and scale are read from BUFFER at call time."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((image (latex-to-svg
                    value
                    :callback (lambda ()
                                (org-latex-to-svg--place buffer beg end value)))))
        (when image
          (org-latex-to-svg--set-overlay beg end value image))))))

(defun org-latex-to-svg--render-element (el)
  "Render math element EL in the current buffer."
  (let* ((bounds (org-latex-to-svg--element-bounds el))
         (value (org-element-property :value el)))
    (org-latex-to-svg--place (current-buffer)
                             (copy-marker (car bounds))
                             (copy-marker (cdr bounds))
                             value)))

(defun org-latex-to-svg--render-region (beg end)
  "Render every math element overlapping BEG..END in the current buffer."
  (dolist (el (org-latex-to-svg--elements beg end))
    (org-latex-to-svg--render-element el)))

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
        (end (or end (point-max))))
    (dolist (el (org-latex-to-svg--elements beg end))
      (latex-to-svg-invalidate (org-element-property :value el)))
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
    (deactivate-mark))
   ((org-latex-to-svg--context)
    (let* ((el (org-latex-to-svg--context))
           (b (org-element-property :begin el))
           (e (org-element-property :end el)))
      (if (org-latex-to-svg--overlays-in b e)
          (org-latex-to-svg--clear-region b e)
        (org-latex-to-svg--render-element el))))
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
