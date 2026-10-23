;;; latex-to-svg-for-markdown.el --- Preview Markdown LaTeX math as SVG -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.25.1
;; Package-Requires: ((emacs "29.1") (latex-to-svg-frontend "0.25.1"))
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
;; is not previewed) and how to unfold a jump target, and enables the core.  All the actual work — detection,
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
;;   (setq-local latex-to-svg-frontend-rescale-display 1.25)

;;; Code:

(require 'latex-to-svg-frontend)
(require 'treesit nil t)

(defconst latex-to-svg-for-markdown-version "0.25.1"
  "The version of `latex-to-svg-for-markdown', as in the `Version:' header.")

(defvar markdown-hide-markup)
(defvar markdown-ts-hide-markup)

(defconst latex-to-svg-for-markdown--code-block-query
  (when (fboundp 'treesit-query-compile)
    (treesit-query-compile
     'markdown '((fenced_code_block) @c (indented_code_block) @c)))
  "The tree-sitter query for Markdown's code blocks, or nil.
Compiled when it is first used, so loading this file needs no grammar.
A query passed as a list is compiled again on every call: 0.5 ms, against
a few microseconds for this one, and `--exclusions' runs at every
keystroke and every command that moves point.  nil in an Emacs built
without tree-sitter.")

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
          ;; `treesit-parser-list' only took a language argument from Emacs
          ;; 30 on, so filter the buffer's parsers ourselves: on 29 the
          ;; extra argument signals, and `wrong-number-of-arguments' is not
          ;; a `treesit-error' the handler below would catch.
          (let* ((existing (seq-find
                            (lambda (p)
                              (eq (treesit-parser-language p) 'markdown))
                            (treesit-parser-list (current-buffer))))
                 (parser (or existing (treesit-parser-create 'markdown))))
            (when parser
              (setq parsed t)
              (dolist (cap (treesit-query-capture
                            (treesit-parser-root-node parser)
                            latex-to-svg-for-markdown--code-block-query
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

(defun latex-to-svg-for-markdown--unhide-markup-in-math (limit)
  "Font-lock keyword: remove the `invisible' property from math source.
With `markdown-ts-hide-markup' or `markdown-hide-markup' on, the
markup hides what it reads as Markdown markup: the `$' of `$...$', and
in `\\(...\\)' and `\\[...\\]' every backslash it reads as an escape,
those of the delimiters and those of `\\{' and `\\}' inside.  These
characters are part of the LaTeX source, so they stay visible when the
source is shown: with no preview, or with point on the equation.

Both modes put `invisible' in `font-lock-extra-managed-props' when they
hide markup, so font-lock sets the property again once this keyword is
removed.  The equations come from `latex-to-svg-frontend-spans', which
looks in the blank-line blocks around POINT..LIMIT: font-lock may
fontify part of an equation that spans several lines, and the markup
hides its delimiters outside that part.  With hiding off, or nothing
hidden in POINT..LIMIT, it does nothing.  Returns nil (own
fontification, one call per chunk)."
  (when (and (or (bound-and-true-p markdown-ts-hide-markup)
                 (bound-and-true-p markdown-hide-markup))
             (< (point) limit)
             (text-property-not-all (point) limit 'invisible nil))
    (dolist (span (latex-to-svg-frontend-spans (point) limit))
      (remove-text-properties (nth 1 span) (nth 2 span) '(invisible nil))))
  (goto-char limit)
  nil)

(defconst latex-to-svg-for-markdown--setext-underline-query
  (when (fboundp 'treesit-query-compile)
    (treesit-query-compile
     'markdown '((setext_h1_underline) @u (setext_h2_underline) @u)))
  "The tree-sitter query for the underlines of setext headings, or nil.
Compiled when it is first used, so loading this file needs no grammar.
nil in an Emacs built without tree-sitter.")

(defun latex-to-svg-for-markdown--put-math-face (beg end)
  "Give BEG..END the face `markdown-ts-mode' gives `$...$' math.
In each face run, remove `markdown-ts-delimiter' and append
`markdown-ts-latex' when it is missing; keep the other faces, such as
the face of a heading the equation is in."
  (let ((p beg))
    (while (< p end)
      (let* ((q (next-single-property-change p 'face nil end))
             (face (get-text-property p 'face))
             (faces (cond ((null face) nil)
                          ((or (symbolp face) (keywordp (car-safe face)))
                           (list face))
                          (t face)))
             (kept (remq 'markdown-ts-delimiter faces)))
        (put-text-property p q 'face
                           (if (memq 'markdown-ts-latex kept)
                               kept
                             (append kept '(markdown-ts-latex))))
        (setq p q)))))

(defun latex-to-svg-for-markdown--math-face (limit)
  "Font-lock keyword: give all math the face of `$...$' math.
In `markdown-ts-mode', only `$...$' and `$$...$$' are math, and get the
face `markdown-ts-latex'.  The grammar reads `\\(' and `\\[' as escaped
parentheses and brackets, which get `markdown-ts-delimiter' on their
backslash, and the text inside them gets no face.  The color of the
text at the opening delimiter tints the preview (see
`latex-to-svg-frontend-foreground-color'), so the same equation was
drawn in the color of `shadow' between `\\[' and `\\]', and in the color
of `markdown-ts-latex' between `$$' and `$$'.

A line holding only `=' or `-' inside an equation is the underline of a
setext heading to the grammar, as CommonMark says: the lines above it,
the opening delimiter included, get `markdown-ts-setext-heading', and
the preview took the color of the heading.  When the underline is
inside an equation, this keyword removes that face from the heading.
A heading whose underline is outside every equation is a
heading: it keeps its face, and so does the math in it.

Each equation found by `latex-to-svg-frontend-spans' gets the face of
`$...$' (`latex-to-svg-for-markdown--put-math-face'), within POINT..LIMIT.
References drawn as text are left alone.  In other modes it does
nothing.  Returns nil (own fontification, one call per chunk)."
  (when (and (derived-mode-p 'markdown-ts-mode)
             (< (point) limit))
    (let ((start (point)))
      (dolist (span (latex-to-svg-frontend-spans start limit))
        (unless (eq (car span) 'reference)
          (let ((beg (nth 1 span))
                (end (nth 2 span)))
            (dolist (cap (ignore-error treesit-error
                           (treesit-query-capture
                            'markdown
                            latex-to-svg-for-markdown--setext-underline-query
                            beg end)))
              (let* ((underline (cdr cap))
                     (heading (treesit-node-parent underline)))
                (when (and (< beg (treesit-node-start underline))
                           (<= (treesit-node-end underline) end))
                  (let ((b (max start (treesit-node-start heading)))
                        (e (min limit (treesit-node-end heading))))
                    (when (< b e)
                      (font-lock--remove-face-from-text-property
                       b e 'face 'markdown-ts-setext-heading))))))
            (let ((b (max start beg))
                  (e (min limit end)))
              (when (< b e)
                (latex-to-svg-for-markdown--put-math-face b e))))))))
  (goto-char limit)
  nil)

(defconst latex-to-svg-for-markdown--font-lock-keywords
  '((latex-to-svg-for-markdown--unhide-markup-in-math)
    (latex-to-svg-for-markdown--math-face))
  "Font-lock keywords added while the mode is on (appended, so they run last).
Turning `latex-to-svg-frontend-mode' on or off fontifies the buffer
again, so they apply at once.")

(defconst latex-to-svg-for-markdown--emphasis-faces
  '(markdown-italic-face markdown-bold-face markdown-strike-through-face
    markdown-highlighting-face
    markdown-ts-emphasis markdown-ts-bold markdown-ts-strikethrough)
  "The emphasis faces of `markdown-mode' and `markdown-ts-mode'.
The value of `latex-to-svg-frontend-emphasis-faces' in Markdown buffers.")

;;;###autoload
(define-minor-mode latex-to-svg-for-markdown-mode
  "Preview Markdown LaTeX math as SVG images (a `latex-to-svg-frontend' adaptor).

Installs the Markdown code/verbatim exclusions and the jump-reveal
\(see `latex-to-svg-frontend--reveal-outline'), then turns on
`latex-to-svg-frontend-mode', which does the rendering.  Enable it from
`markdown-ts-mode-hook' (or `markdown-mode' / `gfm-mode')."
  :lighter nil
  (if latex-to-svg-for-markdown-mode
      (if (latex-to-svg-for-markdown--buffer-p)
          (progn
            (setq-local latex-to-svg-frontend-exclude-function
                        #'latex-to-svg-for-markdown--exclusions)
            (setq-local latex-to-svg-frontend-reveal-function
                        #'latex-to-svg-frontend--reveal-outline)
            (setq-local latex-to-svg-frontend-emphasis-faces
                        latex-to-svg-for-markdown--emphasis-faces)
            (font-lock-add-keywords
             nil latex-to-svg-for-markdown--font-lock-keywords 'append)
            (latex-to-svg-frontend-mode 1))
        (setq latex-to-svg-for-markdown-mode nil)
        (user-error "`latex-to-svg-for-markdown-mode' only works in Markdown buffers"))
    (font-lock-remove-keywords
     nil latex-to-svg-for-markdown--font-lock-keywords)
    (latex-to-svg-frontend-mode -1)
    (kill-local-variable 'latex-to-svg-frontend-exclude-function)
    (kill-local-variable 'latex-to-svg-frontend-reveal-function)
    (kill-local-variable 'latex-to-svg-frontend-emphasis-faces)))

(provide 'latex-to-svg-for-markdown)

;;; latex-to-svg-for-markdown.el ends here
