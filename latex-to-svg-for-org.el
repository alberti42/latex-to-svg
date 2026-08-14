;;; latex-to-svg-for-org.el --- Preview Org LaTeX math as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.13.0
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
;; block/comment regions below are excluded from it.  Inline `~code~' /
;; `=verbatim=' are not yet excluded (see README); disable a delimiter family
;; with the core toggles if a markup character causes false positives.
;;
;; Usage:
;;
;;   (add-hook 'org-mode-hook #'latex-to-svg-for-org-mode)
;;
;; Per-buffer settings are the core's buffer-local variables; set them in the
;; same hook, e.g. `(setq-local latex-to-svg-frontend-display-rescale 1.25)'.

;;; Code:

(require 'latex-to-svg-frontend)

(defun latex-to-svg-for-org--exclusions (_beg end)
  "Return Org code / comment regions up to END to skip.
Covers `#+begin_src' / `example' / `export' / `comment' blocks and whole
comment lines (`# …').  This is the buffer's
`latex-to-svg-frontend-exclude-function'."
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
          (push (cons (match-beginning 0) (match-end 0)) regions))))
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
