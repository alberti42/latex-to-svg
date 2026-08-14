;;; latex-to-svg-for-markdown.el --- Preview Markdown LaTeX math as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.12.1
;; Package-Requires: ((emacs "29.1") (latex-to-svg-frontend "0.11.0"))
;; Keywords: tex, markdown, math, images

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
;; Markdown adaptor for `latex-to-svg-frontend': a thin layer that tells the
;; shared core what counts as "code" in a Markdown buffer (so math inside code
;; is not previewed) and enables the core.  All the actual work — detection,
;; overlays, numbering, references, reveal-on-cursor, refresh — lives in
;; `latex-to-svg-frontend'.
;;
;; Usage:
;;
;;   (add-hook 'markdown-ts-mode-hook #'latex-to-svg-for-markdown-mode)
;;
;; Per-buffer settings (rescale factors, delimiter toggles, …) are the core's
;; buffer-local variables; set them in the same hook, e.g.
;;
;;   (setq-local latex-to-svg-frontend-display-rescale 1.25)

;;; Code:

(require 'latex-to-svg-frontend)
(require 'treesit nil t)

(defun latex-to-svg-for-markdown--exclusions (beg end)
  "Return Markdown code / verbatim regions within BEG..END to skip.
Fenced / indented code blocks via a `markdown' tree-sitter parser when
available, plus inline code spans (`` `…` ``) via regexp so it works with
no grammar installed.  This is the buffer's
`latex-to-svg-frontend-exclude-function'."
  (let ((regions '()))
    (when (and (fboundp 'treesit-available-p) (treesit-available-p)
               (fboundp 'treesit-language-available-p)
               (treesit-language-available-p 'markdown))
      (ignore-errors
        (let ((parser (or (car (treesit-parser-list (current-buffer) 'markdown))
                          (treesit-parser-create 'markdown))))
          (when parser
            (dolist (cap (treesit-query-capture
                          (treesit-parser-root-node parser)
                          '((fenced_code_block) @c
                            (indented_code_block) @c)
                          beg end))
              (let ((n (cdr cap)))
                (push (cons (treesit-node-start n) (treesit-node-end n))
                      regions)))))))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char beg)
        (while (re-search-forward "`+" end t)
          (let* ((b (match-beginning 0))
                 (ticks (- (match-end 0) b)))
            (when (re-search-forward (format "`\\{%d\\}" ticks) end t)
              (push (cons b (match-end 0)) regions))))))
    regions))

(defun latex-to-svg-for-markdown--buffer-p ()
  "Non-nil in a Markdown buffer this adaptor supports."
  (derived-mode-p 'markdown-ts-mode 'markdown-mode 'gfm-mode))

;;;###autoload
(define-minor-mode latex-to-svg-for-markdown-mode
  "Preview Markdown LaTeX math as SVG images (a `latex-to-svg-frontend' adaptor).

Installs the Markdown code/verbatim exclusions and turns on
`latex-to-svg-frontend-mode', which does the rendering.  Enable it from
`markdown-ts-mode-hook' (or `markdown-mode' / `gfm-mode')."
  :lighter nil
  (if latex-to-svg-for-markdown-mode
      (if (latex-to-svg-for-markdown--buffer-p)
          (progn
            (setq-local latex-to-svg-frontend-exclude-function
                        #'latex-to-svg-for-markdown--exclusions)
            (latex-to-svg-frontend-mode 1))
        (setq latex-to-svg-for-markdown-mode nil)
        (user-error "`latex-to-svg-for-markdown-mode' only works in Markdown buffers"))
    (latex-to-svg-frontend-mode -1)
    (kill-local-variable 'latex-to-svg-frontend-exclude-function)))

(provide 'latex-to-svg-for-markdown)

;;; latex-to-svg-for-markdown.el ends here
