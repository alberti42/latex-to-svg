;;; latex-to-svg-for-elfeed.el --- Preview LaTeX math in Elfeed entries as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.23.0
;; Package-Requires: ((emacs "29.1") (latex-to-svg-frontend "0.23.0"))
;; Keywords: tex, news, math, images

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
;; Elfeed adaptor for `latex-to-svg-frontend': previews the LaTeX math of
;; the entry Elfeed shows in `elfeed-show-mode', such as the titles and
;; abstracts of the arXiv feeds.  All the actual work lives in
;; `latex-to-svg-frontend'.
;;
;; Elfeed replaces the text of the entry buffer each time it shows an
;; entry, and when you revert the buffer, so the adaptor draws the
;; previews again from `elfeed-show-update-hook'.  It excludes no region
;; and turns equation numbering off in the entry buffer.
;;
;; Usage:
;;
;;   (add-hook 'elfeed-show-mode-hook #'latex-to-svg-for-elfeed-mode)
;;
;; Per-buffer settings are the core's buffer-local variables; set them in the
;; same hook, e.g. `(setq-local latex-to-svg-frontend-detect-dollar-inline
;; nil)' where `$' is more often currency than math.

;;; Code:

(require 'latex-to-svg-frontend)

(defvar latex-to-svg-for-elfeed-mode)

(defvar-local latex-to-svg-for-elfeed--set-numbering nil
  "Non-nil when the mode set `latex-to-svg-frontend-number-equations'.")

(defun latex-to-svg-for-elfeed--entry-shown ()
  "Draw the previews of the entry Elfeed has just shown.
Elfeed erases the entry buffer and inserts the entry, then runs
`elfeed-show-update-hook' in that buffer, where the mode adds this
function buffer-locally.  It draws every equation of the buffer,
including the one point is in."
  (when latex-to-svg-for-elfeed-mode
    (save-restriction
      (widen)
      (latex-to-svg-frontend--render-region (point-min) (point-max)))))

;;;###autoload
(define-minor-mode latex-to-svg-for-elfeed-mode
  "Preview the LaTeX math of Elfeed entries as SVG images.
A `latex-to-svg-frontend' adaptor for `elfeed-show-mode'.  It turns on
`latex-to-svg-frontend-mode', which does the rendering, and draws the
previews again for each entry Elfeed shows (see
`latex-to-svg-for-elfeed--entry-shown').  In the entry buffer, equation
numbering is off by default: set `latex-to-svg-frontend-number-equations'
buffer-locally to turn it on.  Enable the mode from
`elfeed-show-mode-hook'."
  :lighter nil
  (if latex-to-svg-for-elfeed-mode
      (if (derived-mode-p 'elfeed-show-mode)
          (progn
            (setq-local latex-to-svg-frontend-exclude-function #'ignore)
            (unless (local-variable-p 'latex-to-svg-frontend-number-equations)
              (setq-local latex-to-svg-frontend-number-equations nil)
              (setq latex-to-svg-for-elfeed--set-numbering t))
            ;; Last, so it draws after `elfeed-show-auto-readable', which
            ;; may erase the buffer and show the entry again.
            (add-hook 'elfeed-show-update-hook
                      #'latex-to-svg-for-elfeed--entry-shown 90 t)
            (latex-to-svg-frontend-mode 1))
        (setq latex-to-svg-for-elfeed-mode nil)
        (user-error "`latex-to-svg-for-elfeed-mode' only works in Elfeed entry buffers"))
    (remove-hook 'elfeed-show-update-hook
                 #'latex-to-svg-for-elfeed--entry-shown t)
    (latex-to-svg-frontend-mode -1)
    (kill-local-variable 'latex-to-svg-frontend-exclude-function)
    (when latex-to-svg-for-elfeed--set-numbering
      (kill-local-variable 'latex-to-svg-frontend-number-equations)
      (setq latex-to-svg-for-elfeed--set-numbering nil))))

(provide 'latex-to-svg-for-elfeed)

;;; latex-to-svg-for-elfeed.el ends here
