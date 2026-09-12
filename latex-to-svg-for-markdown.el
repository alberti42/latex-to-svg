;;; latex-to-svg-for-markdown.el --- Preview Markdown LaTeX math as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.16.1
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

(defvar-local latex-to-svg-for-markdown--treesit-warned nil
  "Non-nil once a tree-sitter failure has been reported in this buffer.")

(defconst latex-to-svg-for-markdown--fence-open-re
  "^[ \t]\\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)\\([^\n]*\\)$"
  "Regexp matching a CommonMark opening code fence.
Group 1 is the fence run (3+ backticks or 3+ tildes), group 2 its info string.")

(defconst latex-to-svg-for-markdown--list-item-re
  "\\`[ \t]*\\(?:[-*+][ \t]\\|[0-9]+[.)][ \t]\\)"
  "Regexp matching a list-item line (matched against a whole line string).
An indented run right after such a line is list continuation, not code.")

(defconst latex-to-svg-for-markdown--indent-re "\\`\\(?:    \\|\t\\)"
  "Regexp matching the indentation that opens a CommonMark indented code line.")

(defconst latex-to-svg-for-markdown--blank-re "\\`[ \t]*\\'"
  "Regexp matching a blank line (as a whole-string match).")

(defun latex-to-svg-for-markdown--fence-regions (end)
  "Return CommonMark fenced code block regions, scanning up to END.
Handles both fence characters: 3+ backticks or 3+ tildes.  Per CommonMark
the closing fence must use the same character and be at least as long as
the opening one, so a block opened with four tildes may quote a three-tilde
fence in its body; an unclosed fence runs to the end of the buffer.

Scanning starts at `point-min' (a block straddling the requested range must
be excluded whole) and the close search is unbounded, so this can leave
point past END -- hence the loop guard."
  (let ((regions '()))
    (save-excursion
      (goto-char (point-min))
      (while (and (<= (point) end)
                  (re-search-forward latex-to-svg-for-markdown--fence-open-re
                                     end t))
        (let* ((b (match-beginning 0))
               (fence (match-string 1))
               (info (match-string 2))
               (char (aref fence 0)))
          ;; A backtick fence's info string may not contain a backtick
          ;; (CommonMark); such a line is an inline code span, not a fence.
          (if (and (eq char ?`) (string-search "`" info))
              (goto-char (match-end 1))
            (push (cons b (if (re-search-forward
                               (format "^[ \t]\\{0,3\\}%c\\{%d,\\}[ \t]*$"
                                       char (length fence))
                               nil t)
                              (match-end 0)
                            (point-max)))
                  regions)
            (goto-char (cdar regions))))))
    regions))

(defun latex-to-svg-for-markdown--indented-code-regions (end)
  "Return CommonMark indented (4-space / tab) code block regions up to END.
An indented run only opens a code block after a blank line -- it may not
interrupt a paragraph -- and not right after a list item, where the same
indentation means list continuation.  Deeper list nesting is not modelled:
this is the no-grammar fallback; the tree-sitter parse is exact."
  (let ((regions '())
        (prev-blank t)                  ; start of buffer counts as blank
        (prev-line ""))                 ; last non-blank line seen
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp)) (<= (point) end))
        (let* ((bol (point))
               (eol (line-end-position))
               (line (buffer-substring-no-properties bol eol))
               (blank (string-match-p latex-to-svg-for-markdown--blank-re line)))
          (if (and prev-blank (not blank)
                   (string-match-p latex-to-svg-for-markdown--indent-re line)
                   (not (string-match-p
                         latex-to-svg-for-markdown--list-item-re prev-line)))
              ;; Consume the run: indented or blank lines, ending at the last
              ;; indented one (trailing blanks belong to what follows).
              (let ((last eol))
                (forward-line 1)
                (while (and (not (eobp))
                            (let ((l (buffer-substring-no-properties
                                      (point) (line-end-position))))
                              (cond
                               ((string-match-p
                                 latex-to-svg-for-markdown--indent-re l)
                                (setq last (line-end-position)))
                               ((string-match-p
                                 latex-to-svg-for-markdown--blank-re l)
                                t))))
                  (forward-line 1))
                (push (cons bol last) regions)
                (setq prev-blank t prev-line ""))
            (setq prev-blank blank)
            (unless blank (setq prev-line line))
            (forward-line 1)))))
    regions))

(defun latex-to-svg-for-markdown--exclusions (beg end)
  "Return Markdown code / verbatim regions within BEG..END to skip.
Fenced / indented code blocks via a `markdown' tree-sitter parser when
available, else an equivalent regexp fallback (`--fence-regions' and
`--indented-code-regions'); plus inline code spans via regexp always, so
this works with no grammar installed.  This is the buffer's
`latex-to-svg-frontend-exclude-function'.

A tree-sitter failure is reported once per buffer and then tolerated: the
regexp fallback takes over.  Node names vary between `markdown' grammars,
so a grammar that does not know this query signals rather than matching
nothing."
  (let ((regions '())
        (parsed nil))
    (when (and (fboundp 'treesit-available-p) (treesit-available-p)
               (fboundp 'treesit-language-available-p)
               (treesit-language-available-p 'markdown))
      (condition-case err
          (let ((parser (or (car (treesit-parser-list (current-buffer) 'markdown))
                            (treesit-parser-create 'markdown))))
            (when parser
              (setq parsed t)
              (dolist (cap (treesit-query-capture
                            (treesit-parser-root-node parser)
                            '((fenced_code_block) @c
                              (indented_code_block) @c)
                            beg end))
                (let ((n (cdr cap)))
                  (push (cons (treesit-node-start n) (treesit-node-end n))
                        regions)))))
        (treesit-error
         (setq parsed nil)
         (unless latex-to-svg-for-markdown--treesit-warned
           (setq latex-to-svg-for-markdown--treesit-warned t)
           (display-warning
            'latex-to-svg-for-markdown
            (format "Cannot exclude Markdown code blocks: %s"
                    (error-message-string err))
            :warning)))))
    (save-excursion
      (save-restriction
        (widen)
        ;; Block code without a grammar: fences (both characters) and
        ;; indented blocks.  Skipped when the parse above covered them -- it
        ;; is exact, these regexps only approximate.  Run first: their close
        ;; searches are unbounded and can leave point past END, which would
        ;; break the bounded inline search below.
        (unless parsed
          (setq regions
                (nconc (latex-to-svg-for-markdown--fence-regions end)
                       (latex-to-svg-for-markdown--indented-code-regions end)
                       regions)))
        ;; Inline code spans.  A backtick already inside a block region is
        ;; skipped, so a stray tick in a code block cannot pair with one
        ;; after it and swallow the real math in between.
        (goto-char beg)
        (while (re-search-forward "`+" end t)
          (let* ((b (match-beginning 0))
                 (ticks (- (match-end 0) b))
                 (block (seq-find (lambda (r) (and (>= b (car r)) (< b (cdr r))))
                                  regions)))
            (cond
             (block (goto-char (max (match-end 0) (min end (cdr block)))))
             ((re-search-forward (format "`\\{%d\\}" ticks) end t)
              (push (cons b (match-end 0)) regions)))))))
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
