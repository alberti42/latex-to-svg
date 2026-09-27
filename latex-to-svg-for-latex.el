;;; latex-to-svg-for-latex.el --- Preview LaTeX math as SVG in LaTeX buffers -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/latex-to-svg
;; Version: 0.18.0
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
(require 'format-spec)
(require 'project)

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

;;;; The .aux file

(defvar TeX-output-dir)
(declare-function TeX-master-output-file "tex")
(declare-function TeX-master-directory "tex")

(defcustom latex-to-svg-for-latex-aux-file nil
  "Where the `.aux' file of a LaTeX buffer is, from which references resolve.
nil asks AUCTeX, in `LaTeX-mode': `TeX-master-output-file', which
follows `TeX-master' (a chapter file finds the main file's `.aux') and
`TeX-output-dir'.  Without AUCTeX, the `.aux' next to the file:
`paper.tex' -> `paper.aux'.

A string is a template, filled with `format-spec': `%b' is the base
name of the buffer's file (`paper' for `paper.tex') and `%r' the
project root (`project-root'), or the file's directory outside a
project.  A relative result is relative to the file's directory.  For
example \"._aux/%b.aux\", set globally, or \"%r/build/main.aux\", in a
project's `.dir-locals.el'.

The file is found when the mode turns on."
  :type '(choice (const :tag "Ask AUCTeX, else next to the file" nil)
                 (string :tag "Template"))
  :safe #'stringp
  :group 'latex-to-svg-frontend)

(defvar-local latex-to-svg-for-latex--aux-path nil
  "Absolute path of this buffer's `.aux' file, or nil.
Set when the mode turns on (see `latex-to-svg-for-latex-aux-file').")

(defun latex-to-svg-for-latex--auctex-aux-file ()
  "Return the `.aux' file AUCTeX names for this buffer, or nil without AUCTeX.
`TeX-master-output-file' returns a name relative to the master file's
directory when `TeX-output-dir' is set, else relative to the buffer's."
  (when (and (derived-mode-p 'LaTeX-mode)
             (fboundp 'TeX-master-output-file))
    (expand-file-name (TeX-master-output-file "aux")
                      (if (bound-and-true-p TeX-output-dir)
                          (TeX-master-directory)
                        default-directory))))

(defun latex-to-svg-for-latex--aux-file ()
  "Return the absolute path of this buffer's `.aux' file, or nil.
nil when the buffer visits no file.  See
`latex-to-svg-for-latex-aux-file'."
  (when-let* ((file buffer-file-name))
    (let ((dir (file-name-directory file)))
      (cond
       ((stringp latex-to-svg-for-latex-aux-file)
        (expand-file-name
         (format-spec latex-to-svg-for-latex-aux-file
                      `((?b . ,(file-name-base file))
                        (?r . ,(if-let* ((project (project-current)))
                                   (expand-file-name (project-root project))
                                 dir))))
         dir))
       ((latex-to-svg-for-latex--auctex-aux-file))
       (t (expand-file-name (concat (file-name-base file) ".aux") dir))))))

(defvar-local latex-to-svg-for-latex--aux-mtime nil
  "Modification time of the `.aux' file when it was last read, or nil.")

(defvar-local latex-to-svg-for-latex--labels nil
  "Table from label to printed number, read from the `.aux' file.")

(defconst latex-to-svg-for-latex--brace-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    (modify-syntax-entry ?\\ "\\" table)
    table)
  "Syntax table in which braces pair and a backslash escapes, for `.aux' text.")

(defun latex-to-svg-for-latex--group-at-point ()
  "Return the text of the braced group at point and move past it, or nil.
Point must be on its `{'."
  (when (eq (char-after) ?\{)
    (let ((b (point)))
      (condition-case nil
          (progn (forward-sexp)
                 (buffer-substring-no-properties (1+ b) (1- (point))))
        (scan-error nil)))))

(defun latex-to-svg-for-latex--clean-number (text)
  "Return the printed number TEXT with `\\relax' and surrounding space removed."
  (string-trim (replace-regexp-in-string "\\\\relax\\_>" "" text)))

(defun latex-to-svg-for-latex--read-aux (file labels &optional seen)
  "Add the labels of the `.aux' FILE to the table LABELS.
Each `\\newlabel{LABEL}{{NUMBER}…}' adds LABEL -> NUMBER, the first
group of the second argument: the plain form `{{N}{PAGE}}' and
hyperref's five groups both start with it.  cleveref's `LABEL@cref'
entries are skipped.  `\\@input{CHAPTER.aux}', which `\\include' writes,
is followed, relative to FILE's directory; SEEN holds the files already
read, so a cycle stops."
  (let ((file (expand-file-name file)))
    (unless (or (member file seen) (not (file-readable-p file)))
      (push file seen)
      (let ((inputs '()))
        (with-temp-buffer
          (insert-file-contents file)
          (with-syntax-table latex-to-svg-for-latex--brace-syntax-table
            (goto-char (point-min))
            (while (re-search-forward "^\\\\\\(newlabel\\|@input\\){" nil t)
              (backward-char)
              (let ((kind (match-string 1))
                    (name (latex-to-svg-for-latex--group-at-point)))
                (cond
                 ((null name))
                 ((equal kind "@input") (push name inputs))
                 ((string-suffix-p "@cref" name))
                 ((eq (char-after) ?\{)
                  (forward-char)
                  (when-let* ((number (latex-to-svg-for-latex--group-at-point)))
                    (puthash name (latex-to-svg-for-latex--clean-number number)
                             labels))))))))
        (dolist (input (nreverse inputs))
          (latex-to-svg-for-latex--read-aux
           (expand-file-name input (file-name-directory file)) labels seen))))
    labels))

(defun latex-to-svg-for-latex--labels ()
  "Return the table from label to printed number for this buffer.
Read from the `.aux' file (see `latex-to-svg-for-latex-aux-file') the
first time and whenever its modification time changed since; empty
when there is no `.aux' file, so every reference shows \"??\".  This is
the buffer's `latex-to-svg-frontend-labels-function'."
  (let ((mtime (and latex-to-svg-for-latex--aux-path
                    (file-attribute-modification-time
                     (file-attributes latex-to-svg-for-latex--aux-path)))))
    (unless (and latex-to-svg-for-latex--labels
                 (equal mtime latex-to-svg-for-latex--aux-mtime))
      (setq latex-to-svg-for-latex--aux-mtime mtime
            latex-to-svg-for-latex--labels
            (let ((labels (make-hash-table :test 'equal)))
              (if mtime
                  (latex-to-svg-for-latex--read-aux
                   latex-to-svg-for-latex--aux-path labels)
                labels))))
    latex-to-svg-for-latex--labels))

;;;###autoload
(defun latex-to-svg-for-latex-update-references (&rest _)
  "Re-resolve the references in every buffer where the LaTeX adaptor is on.
A buffer whose `.aux' file changed since it last read it reads it
again (see `latex-to-svg-for-latex--labels'); the others keep their
labels.  References also follow the `.aux' file at the next reconcile,
or at once with `latex-to-svg-frontend-refresh'; this is for AUCTeX's
hook, run when a compile finishes, whose argument (the output file) it
ignores:

  (add-hook \\='TeX-after-compilation-finished-functions
            #\\='latex-to-svg-for-latex-update-references)"
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'latex-to-svg-for-latex-mode buffer)
      (with-current-buffer buffer
        (latex-to-svg-frontend--reconcile-references nil)))))

;;;; Jumping to a label

(declare-function xref-find-backend "xref")
(declare-function xref-backend-identifier-at-point "xref")
(declare-function xref-find-definitions "xref")

(defun latex-to-svg-for-latex--label-in-buffer (label)
  "Return the position of `\\label{LABEL}' in the buffer outside comments, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((needle (format "\\label{%s}" label))
            (pos nil))
        (while (and (not pos) (search-forward needle nil t))
          (unless (latex-to-svg-for-latex--in-comment-p (match-beginning 0))
            (setq pos (match-beginning 0))))
        pos))))

(defun latex-to-svg-for-latex--xref-backend ()
  "Return the buffer's xref backend if it can find a label, else nil.
The two etags backends are excluded: without a `TAGS' file they prompt
for one.  `tex-etags' is Emacs 31's TeX backend, which AUCTeX enables."
  (when (require 'xref nil t)
    (let ((backend (xref-find-backend)))
      (unless (memq backend '(nil etags tex-etags))
        backend))))

(defun latex-to-svg-for-latex--find-label (label)
  "Jump to where LABEL is defined; the `find-label-function' of the buffer.
Called with point on a reference to LABEL that no equation in the
buffer defines.  Jumps to `\\label{LABEL}' elsewhere in the buffer (a
section's, a figure's), else asks xref, with point on the label's name
in the reference: with eglot running texlab, that finds a label in any
file of the document.  Signals a `user-error' when neither finds it."
  (cond
   ((when-let* ((pos (latex-to-svg-for-latex--label-in-buffer label)))
      (push-mark)
      (goto-char pos)
      (when (get-buffer-window (current-buffer)) (recenter))
      (message "Jumped to \\label{%s}" label)
      t))
   ((when-let* ((backend (latex-to-svg-for-latex--xref-backend))
                (ov (latex-to-svg-frontend--ref-overlay-at (point))))
      (goto-char (overlay-start ov))
      (search-forward "{" (overlay-end ov) t)
      (xref-find-definitions (xref-backend-identifier-at-point backend))
      t))
   (t (user-error "\\label{%s} is not in this buffer" label))))

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
`latex-to-svg-for-latex--exclusions'), resolves `\\ref' and `\\eqref'
from the document's `.aux' file (see `latex-to-svg-for-latex-aux-file';
\"??\" for a label it lacks), and turns on `latex-to-svg-frontend-mode',
which does the rendering.  In LaTeX buffers the engine is `latex' by
default, whatever `latex-to-svg-frontend-engine' is set to elsewhere:
RaTeX ignores every preamble and most packages, so equations that use
the project's macros fail with it.  To use RaTeX anyway, set
`latex-to-svg-frontend-engine' buffer-locally, for example in the
project's `.dir-locals.el'.  Enable the mode from
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
            (setq latex-to-svg-for-latex--aux-path
                  (latex-to-svg-for-latex--aux-file))
            (setq-local latex-to-svg-frontend-labels-function
                        #'latex-to-svg-for-latex--labels)
            (setq-local latex-to-svg-frontend-find-label-function
                        #'latex-to-svg-for-latex--find-label)
            (unless (local-variable-p 'latex-to-svg-frontend-engine)
              (setq-local latex-to-svg-frontend-engine 'latex)
              (setq latex-to-svg-for-latex--set-engine t))
            (latex-to-svg-frontend-mode 1))
        (setq latex-to-svg-for-latex-mode nil)
        (user-error "`latex-to-svg-for-latex-mode' only works in LaTeX buffers"))
    (latex-to-svg-frontend-mode -1)
    (kill-local-variable 'latex-to-svg-frontend-exclude-function)
    (kill-local-variable 'latex-to-svg-frontend-labels-function)
    (kill-local-variable 'latex-to-svg-frontend-find-label-function)
    (kill-local-variable 'latex-to-svg-for-latex--aux-path)
    (kill-local-variable 'latex-to-svg-for-latex--aux-mtime)
    (kill-local-variable 'latex-to-svg-for-latex--labels)
    (when latex-to-svg-for-latex--set-engine
      (kill-local-variable 'latex-to-svg-frontend-engine)
      (setq latex-to-svg-for-latex--set-engine nil))))

(provide 'latex-to-svg-for-latex)

;;; latex-to-svg-for-latex.el ends here
