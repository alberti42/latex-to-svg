;;; latex-to-svg-for-org.el --- Preview Org LaTeX math as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.16.1
;; Package-Requires: ((emacs "29.1") (latex-to-svg-frontend "0.11.0"))
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
;; Org adaptor for `latex-to-svg-frontend': a thin layer that tells the shared
;; core which Org regions are code / verbatim / comment (so math inside them is
;; not previewed) and how to unfold a jump target (`org-fold-show-context'),
;; then enables the core.  All the actual work lives in
;; `latex-to-svg-frontend'.
;;
;; Detection uses the core's universal scanner (not `org-element'); the Org
;; block/comment regions below are excluded from it, as are inline `~code~' /
;; `=verbatim=' spans, so `=\(=' stays literal text.  Disable a delimiter
;; family with the core toggles if a markup character still causes false
;; positives.
;;
;; Usage:
;;
;;   (add-hook 'org-mode-hook #'latex-to-svg-for-org-mode)
;;
;; Per-buffer settings are the core's buffer-local variables; set them in the
;; same hook, e.g. `(setq-local latex-to-svg-frontend-display-rescale 1.25)'.

;;; Code:

(require 'latex-to-svg-frontend)

(defvar org-verbatim-re)

(defconst latex-to-svg-for-org--verbatim-fallback-re
  (concat "\\([-[:space:]('\"{]\\|^\\)"                   ; 1: pre char
          "\\(\\([=~]\\)"                                ; 2: whole, 3: marker
          "\\([^[:space:]]\\|[^[:space:]].*?[^[:space:]]\\)" ; 4: body
          "\\3\\)"
          "\\([-[:space:].,:!?;'\")}]\\|$\\)")            ; 5: post char
  "Fallback for `org-verbatim-re', same group layout (2 = the whole span).
Used when Org has not yet computed its emphasis regexps.")

(defun latex-to-svg-for-org--inline-verbatim-regions (beg end)
  "Return inline `~code~' / `=verbatim=' regions between BEG and END.
Uses Org's own `org-verbatim-re' when available so what we skip is exactly
what Org fontifies as verbatim; group 2 is the span including its markers."
  (let ((re (if (and (boundp 'org-verbatim-re) (stringp org-verbatim-re))
                org-verbatim-re
              latex-to-svg-for-org--verbatim-fallback-re))
        (regions '()))
    (save-excursion
      ;; Start one char early so the pre-char alternative can match the
      ;; character just before BEG (BEG itself is usually a block start).
      (goto-char (max (point-min) (1- beg)))
      (while (re-search-forward re end t)
        (push (cons (match-beginning 2) (match-end 2)) regions)
        (goto-char (match-end 2))))
    regions))

(defun latex-to-svg-for-org--exclusions (beg end)
  "Return Org code / verbatim / comment regions in BEG..END to skip.
Covers `#+begin_src' / `example' / `export' / `comment' blocks, whole
comment lines (`# …'), and inline `~code~' / `=verbatim=' spans.  This is
the buffer's `latex-to-svg-frontend-exclude-function'."
  (let ((regions '())
        (case-fold-search t))
    (save-excursion
      (save-restriction
        (widen)
        ;; #+begin_… … #+end_… blocks (src / example / export / comment).
        (goto-char (point-min))
        ;; The closing `#+end_…' search is deliberately unbounded (a block
        ;; straddling END must be excluded whole), so it can leave point past
        ;; END -- guard the loop, or the next bounded search signals
        ;; "Invalid search bound (wrong side of point)".
        (while (and (<= (point) end)
                    (re-search-forward
                     "^[ \t]*#\\+begin_\\(src\\|example\\|export\\|comment\\)\\_>"
                     end t))
          (let ((b (match-beginning 0))
                (kind (match-string 1)))
            (when (re-search-forward
                   (format "^[ \t]*#\\+end_%s\\_>.*$" (regexp-quote kind)) nil t)
              (push (cons b (match-end 0)) regions))))
        ;; Whole comment lines: `# …' or a bare `#'.
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*#\\(?: .*\\)?$" end t)
          (push (cons (match-beginning 0) (match-end 0)) regions))
        ;; Inline `~code~' / `=verbatim='.
        (setq regions
              (nconc (latex-to-svg-for-org--inline-verbatim-regions beg end)
                     regions))))
    regions))

;;;###autoload
(define-minor-mode latex-to-svg-for-org-mode
  "Preview Org LaTeX math as SVG images (a `latex-to-svg-frontend' adaptor).

Installs the Org code/comment exclusions and `org-fold-show-context' as
the jump-reveal, then turns on `latex-to-svg-frontend-mode', which does
the rendering.  Enable it from `org-mode-hook'.  While on, its
\\[latex-to-svg-frontend] shadows Org's classic `org-latex-preview'."
  :lighter nil
  (if latex-to-svg-for-org-mode
      (if (derived-mode-p 'org-mode)
          (progn
            (setq-local latex-to-svg-frontend-exclude-function
                        #'latex-to-svg-for-org--exclusions)
            (setq-local latex-to-svg-frontend-reveal-function
                        (lambda ()
                          (when (fboundp 'org-fold-show-context)
                            (org-fold-show-context 'link-search))))
            (latex-to-svg-frontend-mode 1))
        (setq latex-to-svg-for-org-mode nil)
        (user-error "`latex-to-svg-for-org-mode' only works in Org buffers"))
    (latex-to-svg-frontend-mode -1)
    (kill-local-variable 'latex-to-svg-frontend-exclude-function)
    (kill-local-variable 'latex-to-svg-frontend-reveal-function)))

(provide 'latex-to-svg-for-org)

;;; latex-to-svg-for-org.el ends here
