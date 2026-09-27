;;; latex-to-svg-for-latex.el --- Preview LaTeX math as SVG in LaTeX buffers -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.17.0
;; Package-Requires: ((emacs "29.1") (latex-to-svg-frontend "0.18.0"))
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
;; LaTeX adaptor for `latex-to-svg-frontend': a thin layer that tells the
;; shared core which regions of a LaTeX buffer are comments or verbatim (so
;; math inside them is not previewed), then enables the core.  All the actual
;; work lives in `latex-to-svg-frontend'.
;;
;; It works in built-in `latex-mode' and in AUCTeX's `LaTeX-mode'.  While it
;; is on, AUCTeX's preview-latex commands only say that they are off: they
;; would draw their own images over these.
;;
;; Usage:
;;
;;   (add-hook 'LaTeX-mode-hook #'latex-to-svg-for-latex-mode)  ; AUCTeX
;;   (add-hook 'latex-mode-hook #'latex-to-svg-for-latex-mode)  ; tex-mode.el
;;
;; Per-buffer settings are the core's buffer-local variables; set them in the
;; same hook, e.g. `(setq-local latex-to-svg-frontend-display-rescale 1.25)'.

;;; Code:

(require 'latex-to-svg-frontend)

(declare-function LaTeX-verbatim-environments "latex")
(declare-function LaTeX-verbatim-macros-with-delims "latex")
(declare-function LaTeX-verbatim-macros-with-braces "latex")

;;;; What is not previewed

(defconst latex-to-svg-for-latex--verbatim-environments
  '("verbatim" "verbatim*" "filecontents" "filecontents*")
  "Verbatim environments when AUCTeX is not loaded.
The default of AUCTeX's `LaTeX-verbatim-environments'.")

(defconst latex-to-svg-for-latex--verbatim-macros-with-delims
  '("verb" "verb*")
  "Verbatim macros with delimiters when AUCTeX is not loaded.
The default of AUCTeX's `LaTeX-verbatim-macros-with-delims'.")

(defun latex-to-svg-for-latex--verbatim-environments ()
  "Return the names of the verbatim environments.
AUCTeX's `LaTeX-verbatim-environments' when it is loaded: it includes
the buffer-local additions of AUCTeX's style files, such as
`lstlisting' for `listings'.  Else the same default."
  (if (fboundp 'LaTeX-verbatim-environments)
      (LaTeX-verbatim-environments)
    latex-to-svg-for-latex--verbatim-environments))

(defun latex-to-svg-for-latex--verbatim-macros-with-delims ()
  "Return the names of the verbatim macros with delimiters, like \\verb|…|.
AUCTeX's `LaTeX-verbatim-macros-with-delims' when it is loaded, else
the same default."
  (if (fboundp 'LaTeX-verbatim-macros-with-delims)
      (LaTeX-verbatim-macros-with-delims)
    latex-to-svg-for-latex--verbatim-macros-with-delims))

(defun latex-to-svg-for-latex--verbatim-macros-with-braces ()
  "Return the names of the verbatim macros with braces, like \\path{…}.
AUCTeX's `LaTeX-verbatim-macros-with-braces' when it is loaded (its
default is empty; style files add to it), else none."
  (and (fboundp 'LaTeX-verbatim-macros-with-braces)
       (LaTeX-verbatim-macros-with-braces)))

(defconst latex-to-svg-for-latex--comment-re
  "\\(?:^\\|[^\\]\\)\\(?:\\\\\\\\\\)*\\(%.*\\)$"
  "Regexp whose group 1 is a comment: an unescaped `%' to the end of line.
An even number of backslashes before the `%' (`\\\\%') leaves it
unescaped.")

(defun latex-to-svg-for-latex--in-comment-p (pos)
  "Non-nil when POS is inside a comment (see `--comment-re')."
  (save-excursion
    (save-match-data
      (goto-char (line-beginning-position))
      (and (re-search-forward latex-to-svg-for-latex--comment-re
                              (line-end-position) t)
           (< (match-beginning 1) pos)))))

(defun latex-to-svg-for-latex--block-regions (open-re close-fn end)
  "Return the regions from each match of OPEN-RE up to END to its close.
An opener inside a comment is skipped.  CLOSE-FN is called with point
after the opener and the opener's match data, and returns the end of
the region, or nil when the block is not closed (it is then not
excluded).  The close search is unbounded, so a block that straddles
END is excluded whole; the loop is guarded, since it can leave point
past END."
  (let ((regions '()))
    (goto-char (point-min))
    (while (and (<= (point) end)
                (re-search-forward open-re end t))
      (let ((b (match-beginning 0)))
        (unless (latex-to-svg-for-latex--in-comment-p b)
          (when-let* ((e (funcall close-fn)))
            (push (cons b e) regions)
            (goto-char e)))))
    regions))

(defun latex-to-svg-for-latex--line-regions (re group beg end)
  "Return the regions of GROUP of each match of RE on the lines of BEG..END."
  (let ((regions '()))
    (goto-char beg)
    (beginning-of-line)
    (while (re-search-forward re end t)
      (push (cons (match-beginning group) (match-end group)) regions))
    regions))

(defun latex-to-svg-for-latex--delim-macro-regions (names beg end)
  "Return the regions of the verbatim macros NAMES with delimiters in BEG..END.
Each is `\\NAME', a delimiter character, and text up to the same
character on the same line, as in `\\verb|x|' or `\\verb*+x+'."
  (let ((regions '()))
    (when names
      (goto-char beg)
      (beginning-of-line)
      (let ((re (concat "\\\\" (regexp-opt names) "\\([^[:alpha:][:space:]*]\\)")))
        (while (re-search-forward re end t)
          (let ((b (match-beginning 0))
                (delim (match-string 1)))
            (when (search-forward delim (line-end-position) t)
              (push (cons b (point)) regions))))))
    regions))

(defun latex-to-svg-for-latex--brace-macro-regions (names beg end)
  "Return the regions of the verbatim macros NAMES with braces in BEG..END.
Each is `\\NAME{' and text up to the next `}' on the same line."
  (let ((regions '()))
    (when names
      (goto-char beg)
      (beginning-of-line)
      (let ((re (concat "\\\\" (regexp-opt names) "{")))
        (while (re-search-forward re end t)
          (let ((b (match-beginning 0)))
            (when (search-forward "}" (line-end-position) t)
              (push (cons b (point)) regions))))))
    regions))

(defun latex-to-svg-for-latex--exclusions (beg end)
  "Return the LaTeX comment and verbatim regions in BEG..END to skip.
Covers comments (an unescaped `%' to the end of the line), `comment'
environments, `\\iffalse' … `\\fi', the verbatim environments and
macros (see `latex-to-svg-for-latex--verbatim-environments'), and, in a
file with `\\begin{document}', the preamble and what follows
`\\end{document}'.  This is the buffer's
`latex-to-svg-frontend-exclude-function'."
  (save-excursion
    (save-restriction
      (widen)
      (let ((case-fold-search nil)
            (regions '()))
        ;; The preamble, and what follows \end{document}.
        (goto-char (point-min))
        (when (re-search-forward "^[ \t]*\\\\begin{document}" nil t)
          (push (cons (point-min) (point)) regions)
          (when (re-search-forward "^[ \t]*\\\\end{document}" nil t)
            (push (cons (match-beginning 0) (point-max)) regions)))
        ;; `comment' and verbatim environments.
        (let ((names (cons "comment" (latex-to-svg-for-latex--verbatim-environments))))
          (setq regions
                (nconc (latex-to-svg-for-latex--block-regions
                        (concat "\\\\begin{\\(" (regexp-opt names) "\\)}")
                        (lambda ()
                          (when (search-forward
                                 (format "\\end{%s}" (match-string 1)) nil t)
                            (point)))
                        end)
                       regions)))
        ;; \iffalse … \fi.
        (setq regions
              (nconc (latex-to-svg-for-latex--block-regions
                      "\\\\iffalse\\_>"
                      (lambda ()
                        (when (re-search-forward "\\\\fi\\_>" nil t)
                          (point)))
                      end)
                     regions))
        ;; Verbatim macros and comments, line by line in BEG..END.
        (setq regions
              (nconc (latex-to-svg-for-latex--delim-macro-regions
                      (latex-to-svg-for-latex--verbatim-macros-with-delims)
                      beg end)
                     (latex-to-svg-for-latex--brace-macro-regions
                      (latex-to-svg-for-latex--verbatim-macros-with-braces)
                      beg end)
                     (latex-to-svg-for-latex--line-regions
                      latex-to-svg-for-latex--comment-re 1 beg end)
                     regions))
        regions))))

;;;; preview-latex

(defun latex-to-svg-for-latex-preview-disabled ()
  "Say that AUCTeX's preview is off while `latex-to-svg-for-latex-mode' is on.
The mode remaps the preview-latex commands (`preview-at-point',
`preview-region', `preview-buffer', `preview-document',
`preview-environment', `preview-section') to this command, whatever
key runs them: preview-latex would draw its own images over this
package's.  To use preview-latex, turn `latex-to-svg-for-latex-mode'
off."
  (interactive)
  (message "AUCTeX's preview is off while `latex-to-svg-for-latex-mode' \
is on; turn that mode off to use it"))

(defvar latex-to-svg-for-latex-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (command '(preview-at-point preview-region preview-buffer
                       preview-document preview-environment preview-section))
      (define-key map (vector 'remap command)
                  #'latex-to-svg-for-latex-preview-disabled))
    map)
  "Keymap for `latex-to-svg-for-latex-mode'.
It only remaps the preview-latex commands (see
`latex-to-svg-for-latex-preview-disabled').")

;;;; The mode

(defvar-local latex-to-svg-for-latex--set-engine nil
  "Non-nil when the mode set `latex-to-svg-frontend-engine' in this buffer.")

(defun latex-to-svg-for-latex--buffer-p ()
  "Non-nil in a LaTeX buffer this adaptor supports."
  (derived-mode-p 'latex-mode 'LaTeX-mode))

;;;###autoload
(define-minor-mode latex-to-svg-for-latex-mode
  "Preview LaTeX math as SVG images (a `latex-to-svg-frontend' adaptor).

Installs the LaTeX comment and verbatim exclusions (see
`latex-to-svg-for-latex--exclusions'), sets `latex-to-svg-frontend-engine'
to `latex' in the buffer unless it already has a local value, and turns
on `latex-to-svg-frontend-mode', which does the rendering.  RaTeX
ignores every preamble and most packages, so in a LaTeX document it
fails often; a project's `.dir-locals.el' is applied after the mode
hook and can still choose `ratex'.  Enable the mode from
`LaTeX-mode-hook' (AUCTeX) or `latex-mode-hook'.  While it is on,
AUCTeX's preview-latex commands only say that they are off (see
`latex-to-svg-for-latex-preview-disabled')."
  :lighter nil
  :keymap latex-to-svg-for-latex-mode-map
  (if latex-to-svg-for-latex-mode
      (if (latex-to-svg-for-latex--buffer-p)
          (progn
            (setq-local latex-to-svg-frontend-exclude-function
                        #'latex-to-svg-for-latex--exclusions)
            (unless (local-variable-p 'latex-to-svg-frontend-engine)
              (setq-local latex-to-svg-frontend-engine 'latex)
              (setq latex-to-svg-for-latex--set-engine t))
            (latex-to-svg-frontend-mode 1))
        (setq latex-to-svg-for-latex-mode nil)
        (user-error "`latex-to-svg-for-latex-mode' only works in LaTeX buffers"))
    (latex-to-svg-frontend-mode -1)
    (kill-local-variable 'latex-to-svg-frontend-exclude-function)
    (when latex-to-svg-for-latex--set-engine
      (kill-local-variable 'latex-to-svg-frontend-engine)
      (setq latex-to-svg-for-latex--set-engine nil))))

(provide 'latex-to-svg-for-latex)

;;; latex-to-svg-for-latex.el ends here
