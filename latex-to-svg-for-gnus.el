;;; latex-to-svg-for-gnus.el --- Preview LaTeX math in Gnus articles as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.19.1
;; Package-Requires: ((emacs "29.1") (latex-to-svg-frontend "0.19.1"))
;; Keywords: tex, mail, news, math, images

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
;; Gnus adaptor for `latex-to-svg-frontend': previews the LaTeX math of the
;; article Gnus shows in `gnus-article-mode', such as the abstracts of the
;; arXiv feeds on gwene.org.  All the actual work lives in
;; `latex-to-svg-frontend'.
;;
;; Gnus reuses one article buffer and replaces its text for each article,
;; so the adaptor draws the previews again from `gnus-article-prepare-hook'.
;; It excludes no region, turns equation numbering off in the article
;; buffer, and removes Gnus's emphasis (`gnus-emphasis-alist') from inside
;; math.
;;
;; Usage:
;;
;;   (add-hook 'gnus-article-mode-hook #'latex-to-svg-for-gnus-mode)
;;
;; Per-buffer settings are the core's buffer-local variables; set them in the
;; same hook, e.g. `(setq-local latex-to-svg-frontend-detect-dollar-inline
;; nil)' where `$' is more often currency than math.

;;; Code:

(require 'latex-to-svg-frontend)

(defvar gnus-emphasis-alist)
(defvar gnus-article-emphasis-alist)
(defvar gnus-summary-buffer)
(defvar gnus-article-buffer)
(defvar gnus-hidden-properties)
(defvar latex-to-svg-for-gnus-mode)

(defvar-local latex-to-svg-for-gnus--set-numbering nil
  "Non-nil when the mode set `latex-to-svg-frontend-number-equations'.")

(defun latex-to-svg-for-gnus--emphasis-faces ()
  "Return the faces Gnus gives emphasis in the current article.
They come from the alist `article-emphasize' uses: the summary
buffer's `gnus-article-emphasis-alist', else `gnus-emphasis-alist'."
  (mapcar (lambda (elem) (nth 3 elem))
          (or (condition-case nil
                  (with-current-buffer gnus-summary-buffer
                    gnus-article-emphasis-alist)
                (error nil))
              (and (boundp 'gnus-emphasis-alist) gnus-emphasis-alist))))

(defun latex-to-svg-for-gnus--remove-emphasis ()
  "Remove Gnus's emphasis from inside the math of the current buffer.
`article-emphasize' reads `_x_', `/x/', `*x*' ... as emphasis, also
inside math: it hides the markers with the text properties
`gnus-hidden-properties' (`article-type' `emphasis'), and puts the face
on overlays.  Inside each math span this shows the markers again and
deletes those overlays.  Emphasis cannot reach across a math delimiter,
as its text is word characters and whitespace, so emphasis is either
wholly inside math or wholly outside it."
  (let ((faces (latex-to-svg-for-gnus--emphasis-faces))
        (hidden (cons 'article-type
                      (cons 'emphasis
                            (if (boundp 'gnus-hidden-properties)
                                gnus-hidden-properties
                              '(invisible t))))))
    (with-silent-modifications
      (dolist (el (latex-to-svg-frontend--elements (point-min) (point-max)))
        (let ((b (latex-to-svg-frontend--math-begin el))
              (e (latex-to-svg-frontend--math-end el)))
          (let ((p b))
            (while (< p e)
              (let ((q (next-single-property-change p 'article-type nil e)))
                (when (eq (get-text-property p 'article-type) 'emphasis)
                  (remove-text-properties p q hidden))
                (setq p q))))
          (dolist (ov (overlays-in b e))
            (when (and (memq (overlay-get ov 'face) faces)
                       (<= b (overlay-start ov))
                       (<= (overlay-end ov) e))
              (delete-overlay ov))))))))

(defun latex-to-svg-for-gnus--article-prepared ()
  "Draw the previews of the article Gnus has just prepared.
Gnus erases the article buffer and inserts the next article, then runs
`gnus-article-prepare-hook', to which the mode adds this function.
Gnus runs the hook with the summary buffer current, not the article
buffer, so this works in `gnus-article-buffer', when the mode is on
there.  It draws every equation of the buffer, including the one point
is in."
  (when-let* ((buffer (and (boundp 'gnus-article-buffer)
                           gnus-article-buffer
                           (get-buffer gnus-article-buffer))))
    (with-current-buffer buffer
      (when latex-to-svg-for-gnus-mode
        (save-restriction
          (widen)
          (latex-to-svg-for-gnus--remove-emphasis)
          (latex-to-svg-frontend--render-region (point-min) (point-max)))))))

;;;###autoload
(define-minor-mode latex-to-svg-for-gnus-mode
  "Preview the LaTeX math of Gnus articles as SVG images.
A `latex-to-svg-frontend' adaptor for `gnus-article-mode'.  It turns on
`latex-to-svg-frontend-mode', which does the rendering, and draws the
previews again for each article Gnus shows (see
`latex-to-svg-for-gnus--article-prepared').  In the article buffer,
equation numbering is off by default: set
`latex-to-svg-frontend-number-equations' buffer-locally to turn it on.
Gnus's emphasis is removed from inside math.  Enable the mode from
`gnus-article-mode-hook'."
  :lighter nil
  (if latex-to-svg-for-gnus-mode
      (if (derived-mode-p 'gnus-article-mode)
          (progn
            (setq-local latex-to-svg-frontend-exclude-function #'ignore)
            (unless (local-variable-p 'latex-to-svg-frontend-number-equations)
              (setq-local latex-to-svg-frontend-number-equations nil)
              (setq latex-to-svg-for-gnus--set-numbering t))
            (add-hook 'gnus-article-prepare-hook
                      #'latex-to-svg-for-gnus--article-prepared)
            (latex-to-svg-frontend-mode 1)
            (save-restriction
              (widen)
              (latex-to-svg-for-gnus--remove-emphasis)))
        (setq latex-to-svg-for-gnus-mode nil)
        (user-error "`latex-to-svg-for-gnus-mode' only works in Gnus article buffers"))
    ;; The hook is global: keep it while another article buffer has the mode.
    (unless (seq-some (lambda (buffer)
                        (buffer-local-value 'latex-to-svg-for-gnus-mode buffer))
                      (buffer-list))
      (remove-hook 'gnus-article-prepare-hook
                   #'latex-to-svg-for-gnus--article-prepared))
    (latex-to-svg-frontend-mode -1)
    (kill-local-variable 'latex-to-svg-frontend-exclude-function)
    (when latex-to-svg-for-gnus--set-numbering
      (kill-local-variable 'latex-to-svg-frontend-number-equations)
      (setq latex-to-svg-for-gnus--set-numbering nil))))

(provide 'latex-to-svg-for-gnus)

;;; latex-to-svg-for-gnus.el ends here
