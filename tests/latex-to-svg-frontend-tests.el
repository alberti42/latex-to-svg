;;; latex-to-svg-frontend-tests.el --- Tests for latex-to-svg-frontend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/latex-to-svg

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/latex-to-svg-frontend-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The backend (`latex-to-svg-backend') is stubbed to return a synchronous fake image,
;; so no TeX toolchain or graphical display is needed.  Math detection is a
;; regexp scanner, so most tests run in a plain temp buffer with no tree-sitter
;; grammar required; only the minor-mode enable/disable test needs a real
;; Markdown major mode.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'lisp-mnt)
;; `display-warning' is autoloaded, and `cl-letf' resolving that autoload loads
;; warnings.el, which redefines it -- clobbering a stub installed in the same
;; `cl-letf'.  Load it up front so stubbing it is deterministic.
(require 'warnings)

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))

;; `latex-to-svg-backend' (the backend) is a sibling repo; add it to `load-path' so the
;; module's `(require 'latex-to-svg-backend)' resolves when running from a checkout.
(let ((dir (or (getenv "LATEX_TO_SVG_DIR")
               (expand-file-name "../../latex-to-svg-backend"
                                 (file-name-directory
                                  (or load-file-name buffer-file-name))))))
  (when (file-directory-p dir)
    (add-to-list 'load-path dir)))

;; AUCTeX is optional: the LaTeX adaptor's tests that need it skip
;; themselves without it.  Point `AUCTEX_DIR' at an AUCTeX checkout or build
;; to run them.
(when-let* ((dir (getenv "AUCTEX_DIR")))
  (add-to-list 'load-path dir))

(defconst l2sf-tests--book
  (expand-file-name "fixtures/latex-book/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "A LaTeX book with two `\\include'd chapters, and the `.aux' files LaTeX
wrote for it (with hyperref, cleveref and `\\numberwithin').  To write
them again: `latex main.tex' twice in that directory, keeping only the
`.aux' files.")

(require 'latex-to-svg-backend)
(require 'latex-to-svg-frontend)
(require 'latex-to-svg-for-markdown)
(require 'latex-to-svg-for-org)
(require 'latex-to-svg-for-latex)
;; Built-in; defines `latex-mode' and `latex-mode-hook' for the LaTeX adaptor's tests.
(require 'tex-mode)
;; Built-in on Emacs 31+; only needed for the minor-mode enable/disable test,
;; which skips itself when it (or the `markdown' grammar) is unavailable.
(require 'markdown-ts-mode nil t)

;; --- Stub the backend: synchronous, deterministic, no TeX / no display -------

(defvar l2sf-tests--image 'fake-image)

(defmacro l2sf-tests--with-stub (&rest body)
  "Run BODY with the backend stubbed to return `l2sf-tests--image'."
  (declare (indent 0) (debug t))
  `(let ((l2sf-tests--appearance '("#000" "#fff" 20))
         (l2sf-tests--invalidated nil)
         (l2sf-tests--invalidated-engines nil)
         (l2sf-tests--formats-invalidated 0)
         (l2sf-tests--metadata nil)
         (l2sf-tests--metadata-engines nil)
         (l2sf-tests--last-rescale nil)
         (l2sf-tests--last-args nil)
         (l2sf-tests--calls nil)
         (l2sf-tests--missing-engines nil)
         (l2sf-tests--engine-used nil)
         (latex-to-svg-backend-metadata-prefix nil))
     (cl-letf (((symbol-function 'latex-to-svg-backend)
                (lambda (latex &rest args)
                  (setq l2sf-tests--last-rescale (plist-get args :rescale-by)
                        l2sf-tests--last-args args)
                  (push (cons latex (plist-get args :engine)) l2sf-tests--calls)
                  l2sf-tests--image))
               ((symbol-function 'latex-to-svg-backend-engine-used)
                (lambda (_latex &optional engine _fallback)
                  (or l2sf-tests--engine-used engine)))
               ((symbol-function 'latex-to-svg-backend-tools-available-p)
                (lambda (&optional engine)
                  (not (memq engine l2sf-tests--missing-engines))))
               ((symbol-function 'latex-to-svg-backend-appearance)
                (lambda (&optional _font-height) l2sf-tests--appearance))
               ((symbol-function 'latex-to-svg-backend-metadata)
                (lambda (value &optional engine)
                  (push engine l2sf-tests--metadata-engines)
                  (cdr (assoc value l2sf-tests--metadata))))
               ((symbol-function 'latex-to-svg-backend-invalidate)
                (lambda (latex &optional engine)
                  (push latex l2sf-tests--invalidated)
                  (push engine l2sf-tests--invalidated-engines)))
               ((symbol-function 'latex-to-svg-backend-invalidate-format)
                (lambda () (cl-incf l2sf-tests--formats-invalidated))))
       ,@body)))

(defmacro l2sf-tests--md (text &rest body)
  "In a temp buffer containing TEXT, run BODY.
A plain buffer suffices — detection is a regexp scanner."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun l2sf-tests--overlays ()
  "Return this package's overlays in the current buffer, sorted by start."
  (sort (latex-to-svg-frontend--overlays-in (point-min) (point-max))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun l2sf-tests--values (&optional overlays)
  "Return the `-value' property of OVERLAYS (default all)."
  (mapcar (lambda (o) (overlay-get o 'latex-to-svg-frontend-value))
          (or overlays (l2sf-tests--overlays))))

;;;; Detection

(ert-deftest l2sf-detects-fragments-and-environments ()
  ;; The scanner finds inline `$…$' / `\(…\)', display `\[…\]' / `$$…$$', and
  ;; environments, returning each element's verbatim source (delimiters and
  ;; all — exactly what the verbatim backend wants).
  (l2sf-tests--md
      "Inline $E=mc^2$ and \\(a+b\\).\n\nDisplay \\[F=ma\\] then $$g$$\n\n\\begin{equation}\nx=1\n\\end{equation}\n"
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$E=mc^2$"
                     "\\(a+b\\)"
                     "\\[F=ma\\]"
                     "$$g$$"
                     ;; Unlike Org's `latex-environment', our record keeps no
                     ;; trailing newline — bounds cover exactly the source.
                     "\\begin{equation}\nx=1\n\\end{equation}")))))

(ert-deftest l2sf-exclude-function-honored ()
  ;; The core skips any opener inside a region returned by the buffer-local
  ;; `exclude-function' (grammar-independent: a trivial region-returning fn).
  (l2sf-tests--md "keep $a$ then DROP $b$ end\n"
    (setq-local latex-to-svg-frontend-exclude-function
                (lambda (_beg _end)
                  (save-excursion
                    (goto-char (point-min))
                    (when (search-forward "DROP" nil t)
                      (list (cons (match-beginning 0) (point-max)))))))
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$")))))

(ert-deftest l2sf-scan-advancing-cursor-multiple-regions ()
  ;; The sorted-region advancing cursor must exclude openers inside every code
  ;; region and keep the ones between/after them, across many regions and with
  ;; a nested region (start-sorted, overlapping) thrown in.
  (l2sf-tests--md
      (concat "$a$ CODE1 $skip1$ END "      ; region 1
              "$b$ "                          ; kept, between regions
              "CODE2 $skip2$ NEST $skip3$ END " ; region 2, with a nested region
              "$c$\n")                        ; kept, after all regions
    (setq-local latex-to-svg-frontend-exclude-function
                (lambda (_beg _end)
                  (save-excursion
                    (let (regions)
                      ;; Intentionally return them out of order and with one
                      ;; region nested inside another to exercise the sort +
                      ;; overlap-correctness of the cursor.
                      (goto-char (point-min))
                      (when (search-forward "CODE2" nil t)
                        (let ((b (match-beginning 0)))
                          (search-forward "END" nil t)
                          (push (cons b (point)) regions)))
                      (goto-char (point-min))
                      (when (search-forward "NEST" nil t)
                        (let ((b (match-beginning 0)))
                          (search-forward "skip3$" nil t)
                          (push (cons b (point)) regions))) ; nested in CODE2
                      (goto-char (point-min))
                      (when (search-forward "CODE1" nil t)
                        (let ((b (match-beginning 0)))
                          (search-forward "END" nil t)
                          (push (cons b (point)) regions)))
                      regions))))
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$" "$b$" "$c$")))))

(ert-deftest l2sf-markdown-adaptor-skips-code ()
  ;; The Markdown adaptor's exclude-function skips inline code spans (always)
  ;; and fenced code blocks (when the `markdown' grammar is available).
  (l2sf-tests--md "span `code $skip$` and $a$\n"
    (setq-local latex-to-svg-frontend-exclude-function
                #'latex-to-svg-for-markdown--exclusions)
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$"))))
  (when (and (fboundp 'treesit-available-p) (treesit-available-p)
             (treesit-language-available-p 'markdown))
    (l2sf-tests--md "before $a$\n\n```\ncode $skip$\n```\n\nafter $b$\n"
      (setq-local latex-to-svg-frontend-exclude-function
                  #'latex-to-svg-for-markdown--exclusions)
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$a$" "$b$"))))))

(defmacro l2sf-tests--no-treesit (&rest body)
  "Run BODY with tree-sitter reported unavailable (exercise the fallback)."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'treesit-available-p) (lambda () nil)))
     ,@body))

(defun l2sf-tests--md-values ()
  "Return the detected math of the current buffer under the Markdown adaptor."
  (setq-local latex-to-svg-frontend-exclude-function
              #'latex-to-svg-for-markdown--exclusions)
  (mapcar #'latex-to-svg-frontend--math-value
          (latex-to-svg-frontend--elements (point-min) (point-max))))

(ert-deftest l2sf-markdown-adaptor-fallback-block-code ()
  ;; With no `markdown' grammar, block code is still excluded by regexp:
  ;; both fence characters (CommonMark allows 3+ tildes as well as backticks)
  ;; and 4-space / tab indented code blocks.
  (l2sf-tests--no-treesit
    (l2sf-tests--md
        (concat "before $a$\n\n```\n$skip1$\n```\n\n~~~python\n$skip2$\n~~~\n\n"
                "    indented $skip3$\n    more $skip4$\n\nafter $b$\n")
      (should (equal (l2sf-tests--md-values) '("$a$" "$b$"))))))

(ert-deftest l2sf-markdown-adaptor-fallback-longer-fence ()
  ;; A fence may be quoted inside a longer one of the same character: the
  ;; close must be at least as long as the open, so the inner `~~~' lines are
  ;; body, not delimiters.
  (l2sf-tests--no-treesit
    (l2sf-tests--md "~~~~\n~~~\n$skip$\n~~~\n~~~~\n\nafter $b$\n"
      (should (equal (l2sf-tests--md-values) '("$b$"))))
    ;; An unclosed fence swallows the rest of the buffer (as Markdown does).
    (l2sf-tests--md "```\n$skip$\n"
      (should (equal (l2sf-tests--md-values) '())))))

(ert-deftest l2sf-markdown-adaptor-fallback-indent-false-positives ()
  ;; Indentation is only code when it may be: not as list continuation, and
  ;; not interrupting a paragraph.  Strikethrough (`~~…~~') is emphasis, not
  ;; a fence.
  (l2sf-tests--no-treesit
    (l2sf-tests--md "- item\n\n    continuation $a$\n\npara $b$\n"
      (should (equal (l2sf-tests--md-values) '("$a$" "$b$"))))
    (l2sf-tests--md "1. item\n\n    continuation $a$\n\npara $b$\n"
      (should (equal (l2sf-tests--md-values) '("$a$" "$b$"))))
    (l2sf-tests--md "paragraph\n    lazy continuation $a$\n\npara $b$\n"
      (should (equal (l2sf-tests--md-values) '("$a$" "$b$"))))
    (l2sf-tests--md "text ~~struck $a$~~ more $b$\n"
      (should (equal (l2sf-tests--md-values) '("$a$" "$b$"))))))

(ert-deftest l2sf-org-adaptor-skips-code-and-comments ()
  ;; The Org adaptor's exclude-function skips #+begin_src blocks and comment
  ;; lines (pure regexp — no grammar needed).
  (l2sf-tests--md
      "text $a$\n\n#+begin_src python\nprint($skip$)\n#+end_src\n\n# comment $skip$\n\nmore $b$\n"
    (setq-local latex-to-svg-frontend-exclude-function
                #'latex-to-svg-for-org--exclusions)
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$" "$b$")))))

(ert-deftest l2sf-org-adaptor-skips-inline-verbatim ()
  ;; `=verbatim=' / `~code~' spans are literal text: a math delimiter typed
  ;; inside them (e.g. writing about `=\(=') must not be previewed, while real
  ;; math on the same line still is.  Uses Org's own `org-verbatim-re'.
  (skip-unless (and (require 'org nil t)
                    (boundp 'org-verbatim-re) (stringp org-verbatim-re)))
  (l2sf-tests--md
      "I typed =\\(= and =\\)= but \\(y\\) is math, ~\\[z\\]~ is not.\n"
    (setq-local latex-to-svg-frontend-exclude-function
                #'latex-to-svg-for-org--exclusions)
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("\\(y\\)")))))

(ert-deftest l2sf-org-adaptor-inline-verbatim-fallback ()
  ;; Same, with Org's own `org-verbatim-re' unavailable: the built-in fallback
  ;; regexp must cover it (and must not swallow `=' used as an operator).
  (l2sf-tests--md
      "Prose =\\(= here; x = 1 and y = 2; $a=b$ then $c=d$.\n"
    (let ((org-verbatim-re nil))         ; force the fallback
      (setq-local latex-to-svg-frontend-exclude-function
                  #'latex-to-svg-for-org--exclusions)
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$a=b$" "$c=d$"))))))

(ert-deftest l2sf-org-adaptor-block-straddling-end ()
  ;; A bounded scan (as `--element-at' does) whose END falls *inside* a
  ;; `#+begin_src' block must not signal: the unbounded `#+end_src' search
  ;; leaves point past END, and the next bounded search would then complain
  ;; "Invalid search bound (wrong side of point)".
  (l2sf-tests--md
      "#+begin_src python\nprint($skip$)\n#+end_src\n\nmore $b$\n"
    (setq-local latex-to-svg-frontend-exclude-function
                #'latex-to-svg-for-org--exclusions)
    (let ((end (save-excursion (goto-char (point-min)) (line-end-position 2))))
      (should (equal (latex-to-svg-for-org--exclusions (point-min) end)
                     (list (cons (point-min)
                                 (save-excursion
                                   (goto-char (point-min))
                                   (line-end-position 3)))))))
    ;; And the scanner itself survives such a region.
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$b$")))))

(ert-deftest l2sf-inline-dollar-currency-guards ()
  ;; pandoc-style guards on inline `$…$': an opener must be followed by a
  ;; non-space, a closer preceded by one, and `\$' is escaped.  So spaced
  ;; currency is not math, while real math (and adjacent no-space ranges,
  ;; which is the residual the toggle is for) behave as documented.
  (dolist (case '(("I have $30 and you have $50" . ())      ; rule 2: closer after space
                  ("cost 30$ and 50$ each"       . ())      ; rule 1: opener before space
                  ("escaped \\$5 and \\$9 here"   . ())      ; escaped \$
                  ("some $\\alpha$ inline"        . ("$\\alpha$"))
                  ("real $x+y$ math"             . ("$x+y$"))
                  ("a range $100-$200 wide"      . ("$100-$")))) ; residual misfire
    (l2sf-tests--md (concat (car case) "\n")
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     (cdr case))))))

(ert-deftest l2sf-toggle-dollar-inline-off ()
  ;; Disabling inline `$…$' leaves display `$$…$$' (and brackets) detected —
  ;; the point of the split: kill the currency-prone inline dollar only.
  (l2sf-tests--md "$a$ and $$b$$ and \\(c\\)\n"
    (let ((latex-to-svg-frontend-detect-dollar-inline nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$$b$$" "\\(c\\)"))))))

(ert-deftest l2sf-toggle-dollar-display-off ()
  ;; Disabling display `$$…$$' leaves inline `$…$' detected.
  (l2sf-tests--md "$a$ and $$b$$\n"
    (let ((latex-to-svg-frontend-detect-dollar-display nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$a$"))))))

(ert-deftest l2sf-toggle-bracket-inline-off ()
  ;; Disabling inline `\(…\)' leaves display `\[…\]' (and dollars) detected.
  (l2sf-tests--md "$a$ and \\(b\\) and \\[c\\]\n"
    (let ((latex-to-svg-frontend-detect-bracket-inline nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$a$" "\\[c\\]"))))))

(ert-deftest l2sf-toggle-bracket-display-off ()
  ;; Disabling display `\[…\]' leaves inline `\(…\)' detected.
  (l2sf-tests--md "\\(b\\) and \\[c\\]\n"
    (let ((latex-to-svg-frontend-detect-bracket-display nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("\\(b\\)"))))))

(ert-deftest l2sf-toggle-environments-off ()
  (l2sf-tests--md "$a$\n\n\\begin{equation}\nx\n\\end{equation}\n"
    (let ((latex-to-svg-frontend-detect-environments nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$a$"))))))

(ert-deftest l2sf-environment-must-start-its-line ()
  ;; `\begin{ENV}' opens a block-level environment, so it is only an opener
  ;; when nothing but whitespace precedes it on its line.  Prose that merely
  ;; mentions `\begin{...}' mid-sentence stays prose — and the scan resumes
  ;; after it, so later math on the same line is still found.
  (l2sf-tests--md
      (concat "Type \\begin{equation} to open one, as in $a$\n\n"
              "\\begin{equation}\nx\n\\end{equation}\n\n"
              "  \t\\begin{align}\ny&=1\n\\end{align}\n")
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$"
                     "\\begin{equation}\nx\n\\end{equation}"
                     ;; Indentation (spaces and tabs) is allowed.
                     "\\begin{align}\ny&=1\n\\end{align}")))))

(ert-deftest l2sf-environment-mid-line-close-still-closes ()
  ;; The line-start rule applies to the *opener* only: the matching
  ;; `\end{ENV}' may sit anywhere, including after content on its line.
  (l2sf-tests--md "\\begin{equation}\nx=1 \\end{equation}\n"
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("\\begin{equation}\nx=1 \\end{equation}")))))

(ert-deftest l2sf-environments-list-filters-by-name ()
  ;; Only environments named in `latex-to-svg-frontend-environments' are
  ;; rendered; anything else is left as literal source even at line start.
  (l2sf-tests--md
      (concat "\\begin{equation}\nx\n\\end{equation}\n\n"
              "\\begin{itemize}\n\\item a\n\\end{itemize}\n\n"
              "\\begin{tikzpicture}\n\\draw (0,0);\n\\end{tikzpicture}\n")
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("\\begin{equation}\nx\n\\end{equation}")))
    ;; Extending the list opts an environment in.
    (let ((latex-to-svg-frontend-environments
           (cons "tikzpicture" latex-to-svg-frontend-environments)))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("\\begin{equation}\nx\n\\end{equation}"
                       "\\begin{tikzpicture}\n\\draw (0,0);\n\\end{tikzpicture}"))))
    ;; t means any environment.
    (let ((latex-to-svg-frontend-environments t))
      (should (= 3 (length (latex-to-svg-frontend--elements
                            (point-min) (point-max))))))))

(ert-deftest l2sf-environments-list-ignores-trailing-star ()
  ;; A starred form is enabled by its unstarred name (the common case), and an
  ;; explicitly starred entry matches as written.
  (l2sf-tests--md
      (concat "\\begin{equation*}\nx\n\\end{equation*}\n\n"
              "\\begin{align*}\ny&=1\n\\end{align*}\n")
    (should (= 2 (length (latex-to-svg-frontend--elements (point-min) (point-max)))))
    (let ((latex-to-svg-frontend-environments '("align*")))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("\\begin{align*}\ny&=1\n\\end{align*}"))))))

(ert-deftest l2sf-environments-list-subordinate-to-toggle ()
  ;; `-detect-environments' nil switches the whole family off, whatever the
  ;; name list says.
  (l2sf-tests--md "\\begin{equation}\nx\n\\end{equation}\n"
    (let ((latex-to-svg-frontend-detect-environments nil)
          (latex-to-svg-frontend-environments t))
      (should (null (latex-to-svg-frontend--elements (point-min) (point-max)))))))

(ert-deftest l2sf-environments-default-matches-numbered-set ()
  ;; Drift guard: the default render list is exactly the set of environments
  ;; the numbering code knows how to count.
  (should (equal (sort (copy-sequence
                        (default-value 'latex-to-svg-frontend-environments))
                       #'string<)
                 (sort (copy-sequence
                        latex-to-svg-frontend--numbered-environments-all)
                       #'string<))))

(ert-deftest l2sf-inner-environment-not-a-top-level-opener ()
  ;; Environments that are only valid inside a display (`pmatrix', `cases')
  ;; are not top-level previews, but still render as part of the span that
  ;; encloses them.
  (l2sf-tests--md
      (concat "\\begin{equation}\n"
              "A=\\begin{pmatrix}a\\\\b\\end{pmatrix}\n"
              "\\end{equation}\n\n"
              "\\begin{pmatrix}a\\\\b\\end{pmatrix}\n")
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("\\begin{equation}\nA=\\begin{pmatrix}a\\\\b\\end{pmatrix}\n\\end{equation}")))))

(ert-deftest l2sf-toggle-references-off ()
  (l2sf-tests--md "see \\eqref{eq:a} and $x$\n"
    (let ((latex-to-svg-frontend-detect-references nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$x$"))))))

(ert-deftest l2sf-ignores-escaped-dollar ()
  ;; A backslash-escaped `\$' is not a math delimiter.
  (l2sf-tests--md "price \\$5 and \\$9, then real $x$\n"
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$x$")))))

(ert-deftest l2sf-close-search-stops-at-blank-line ()
  ;; A LaTeX math span may not contain a blank line, so an unbalanced opener
  ;; never runs away into a later paragraph: `$a' (open) and `b$' (in the next
  ;; paragraph) do not pair up, and neither is detected.
  (l2sf-tests--md "$a\n\nb$ more\n"
    (should (null (latex-to-svg-frontend--elements (point-min) (point-max)))))
  ;; A complete fragment is still found, and a stray `$' in another paragraph
  ;; is not merged into it.
  (l2sf-tests--md "text $a$ end\n\nprice is $5 today\n"
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$"))))
  ;; An unterminated environment does not swallow a following equation.
  (l2sf-tests--md
      "\\begin{equation}\nx\n\nprose\n\n\\begin{equation}\ny\n\\end{equation}\n"
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("\\begin{equation}\ny\n\\end{equation}")))))

(ert-deftest l2sf-element-bounds-cover-source ()
  (l2sf-tests--md "$x$   after\n"
    (let* ((el (car (latex-to-svg-frontend--elements (point-min) (point-max))))
           (bounds (latex-to-svg-frontend--element-bounds el)))
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "$x$")))))

;;;; Rendering / overlays

(ert-deftest l2sf-renders-overlay-per-element ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ and \\[b\\]\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ovs (l2sf-tests--overlays)))
        (should (= (length ovs) 2))
        (should (equal (l2sf-tests--values ovs) '("$a$" "\\[b\\]")))
        (should (cl-every (lambda (o) (eq (overlay-get o 'display) 'fake-image)) ovs))
        (should (equal (buffer-substring-no-properties
                        (overlay-start (car ovs)) (overlay-end (car ovs)))
                       "$a$"))))))

(ert-deftest l2sf-overlay-neutralizes-strike-through ()
  "Preview overlays carry a face that turns off strike-through/underline,
so markup font-lock (e.g. Org emphasis) never draws a line across the image."
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ and \\[b\\]\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (dolist (ov (l2sf-tests--overlays))
        (let ((face (overlay-get ov 'face)))
          (should (eq (plist-get face :strike-through) nil))
          (should (eq (plist-get face :underline) nil))
          (should (eq (plist-get face :overline) nil))
          ;; Bold / italic emphasis is spurious inside math too.
          (should (eq (plist-get face :weight) 'normal))
          (should (eq (plist-get face :slant) 'normal))
          ;; Explicitly present (not merely absent) so it overrides the
          ;; text-property face beneath.
          (should (plist-member face :strike-through))
          (should (overlay-get ov 'priority)))))))

(ert-deftest l2sf-suppress-emphasis-neutralizes-source ()
  "The font-lock pass removes spurious emphasis face from raw math source
(no overlay), colour and all."
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[a^{(+)} + b^{(+)}\\]\n"
      ;; Simulate a markup emphasis fontifier having struck part of the math.
      (put-text-property (+ (point-min) 3) (- (point-max) 3)
                         'face '(:strike-through t))
      (goto-char (point-min))
      (latex-to-svg-frontend--suppress-emphasis (point-max))
      ;; The spurious face is gone entirely.
      (should (null (get-text-property (+ (point-min) 5) 'face))))))

(ert-deftest l2sf-suppress-emphasis-clears-cross-equation-bridge ()
  "A verbatim/emphasis run opened by a marker inside one equation and closed
inside the next paints the prose in between; the whole run is neutralized."
  (l2sf-tests--with-stub
    (l2sf-tests--md "XX \\(\\Delta{=}0\\)\nIso \\(\\Delta{=}1\\)\n"
      ;; Emulate org: verbatim face from the `=' in line 1 to the `=' in line 2,
      ;; spanning the prose "Iso " between the two equations.
      (let* ((eq1= (1+ (string-match "{=}" (buffer-string))))
             (eq2= (1+ (string-match "{=}" (buffer-string) (1+ eq1=)))))
        (put-text-property eq1= (1+ eq2=) 'face 'org-verbatim)
        (goto-char (point-min))
        (latex-to-svg-frontend--suppress-emphasis (point-max))
        ;; The prose "Iso" between the equations must be fully cleared.
        (let* ((iso (1+ (string-match "Iso" (buffer-string))))
               (face (get-text-property iso 'face)))
          (should (null face)))))))

(ert-deftest l2sf-suppress-emphasis-keeps-prose-emphasis-around-math ()
  "Legitimate prose emphasis whose markers are outside every math span (it
merely *contains* inline math) is left untouched."
  (l2sf-tests--with-stub
    (l2sf-tests--md "a *bold with \\(x\\) inside* b\n"
      ;; Emphasis run spans the whole `*...*', markers in prose, math nested in.
      (let ((beg (string-match "\\*" (buffer-string))))
        (put-text-property (1+ beg)
                           (1+ (string-match "\\* b" (buffer-string)))
                           'face 'bold)
        (goto-char (point-min))
        (latex-to-svg-frontend--suppress-emphasis (point-max))
        ;; "bold" (prose, before the math) keeps its bold face untouched.
        (let ((face (get-text-property
                     (1+ (string-match "bold" (buffer-string))) 'face)))
          (should (eq face 'bold)))))))

(ert-deftest l2sf-suppress-emphasis-respects-toggle ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[a^{(+)} + b^{(+)}\\]\n"
      (let ((latex-to-svg-frontend-suppress-emphasis nil))
        (put-text-property (+ (point-min) 3) (- (point-max) 3)
                           'face '(:strike-through t))
        (goto-char (point-min))
        (latex-to-svg-frontend--suppress-emphasis (point-max))
        (should (equal (get-text-property (+ (point-min) 5) 'face)
                       '(:strike-through t)))))))

(ert-deftest l2sf-clears-overlays ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ $b$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (= 2 (length (l2sf-tests--overlays))))
      (latex-to-svg-frontend--clear-region (point-min) (point-max))
      (should (null (l2sf-tests--overlays))))))

(ert-deftest l2sf-overlay-reveals-on-edit ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (+ (point-min) 1))
      (insert "x")
      (let ((ov (car (l2sf-tests--overlays))))
        (should ov)
        (should (null (overlay-get ov 'display)))
        (should (overlay-get ov 'latex-to-svg-frontend-modified))))))

(ert-deftest l2sf-reveals-preview-under-cursor ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ after\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ov (car (l2sf-tests--overlays))))
        (goto-char (+ (point-min) 1))
        (latex-to-svg-frontend--handle-cursor)
        (should (null (overlay-get ov 'display)))
        (goto-char (point-max))
        (latex-to-svg-frontend--handle-cursor)
        (should (eq (overlay-get ov 'display) 'fake-image))))))

(ert-deftest l2sf-cursor-jump-between-previews ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ $b$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ovs (l2sf-tests--overlays)))
        (goto-char (+ (point-min) 1))
        (latex-to-svg-frontend--handle-cursor)
        (should (null (overlay-get (nth 0 ovs) 'display)))
        (goto-char (overlay-start (nth 1 ovs)))
        (latex-to-svg-frontend--handle-cursor)
        (should (eq (overlay-get (nth 0 ovs) 'display) 'fake-image))
        (should (null (overlay-get (nth 1 ovs) 'display)))))))

(ert-deftest l2sf-heal-rerenders-left-edit ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ after\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (+ (point-min) 1))
      (insert "b")
      (goto-char (point-max))
      (let ((l2sf-tests--image 'healed))
        (latex-to-svg-frontend--heal-modified))
      (let ((ov (car (l2sf-tests--overlays))))
        (should (eq (overlay-get ov 'display) 'healed))
        (should (equal (overlay-get ov 'latex-to-svg-frontend-value) "$ba$"))
        (should-not (overlay-get ov 'latex-to-svg-frontend-modified))))))

(ert-deftest l2sf-rerenders-after-reveal-edit ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ after\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (+ (point-min) 1))
      (latex-to-svg-frontend--handle-cursor)
      (insert "b")
      (let ((l2sf-tests--image 'redrawn))
        (goto-char (point-max))
        (latex-to-svg-frontend--handle-cursor))
      (let ((ov (car (l2sf-tests--overlays))))
        (should (eq (overlay-get ov 'display) 'redrawn))
        (should (equal (overlay-get ov 'latex-to-svg-frontend-value) "$ba$"))))))

(ert-deftest l2sf-auto-renders-new-equation-on-leave ()
  ;; A brand-new equation typed after the initial render renders itself the
  ;; moment point leaves its span (event-driven; no idle timer).
  (l2sf-tests--with-stub
    (l2sf-tests--md "intro text\n\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (null (l2sf-tests--overlays)))
      (goto-char (point-max))
      (insert "\\begin{equation}\nx=1\n\\end{equation}")
      (goto-char (- (point) 3))                  ; put point inside the new block
      (latex-to-svg-frontend--handle-cursor) ; register cursor inside
      (should (null (l2sf-tests--overlays)))   ; not rendered while inside
      (goto-char (point-min))                    ; leave the span
      (latex-to-svg-frontend--handle-cursor) ; -> renders on leave
      (let ((ovs (l2sf-tests--overlays)))
        (should (= 1 (length ovs)))
        (should (string-prefix-p "\\setcounter{equation}{0}%\n\\begin{equation}"
                                 (overlay-get (car ovs)
                                              'latex-to-svg-frontend-value)))
        (should (eq (overlay-get (car ovs) 'display) 'fake-image))))))

(ert-deftest l2sf-leave-reconciles-downstream-synchronously ()
  ;; Leaving a newly typed equation renumbers downstream previews right then,
  ;; on the cursor-leave event itself — no debounced timer, no explicit
  ;; `--reconcile' call (that path is now synchronous).
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n\\begin{equation}\nb\n\\end{equation}\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      ;; The lone equation is number 1.
      (should (string-prefix-p
               "\\setcounter{equation}{0}%"
               (overlay-get (car (l2sf-tests--overlays))
                            'latex-to-svg-frontend-value)))
      ;; Type a new numbered equation above it and leave the new span.
      (goto-char (point-min))
      (insert "\\begin{equation}\na\n\\end{equation}\n\n")
      (goto-char 20)                             ; inside the new block
      (latex-to-svg-frontend--handle-cursor) ; register cursor inside
      (goto-char (point-max))                    ; leave the span
      (latex-to-svg-frontend--handle-cursor) ; renders + reconciles now
      (let ((ovs (l2sf-tests--overlays)))
        (should (= 2 (length ovs)))
        ;; The pre-existing equation is now number 2, updated on leave.
        (should (string-prefix-p
                 "\\setcounter{equation}{1}%"
                 (overlay-get (car (last ovs))
                              'latex-to-svg-frontend-value)))))))

(ert-deftest l2sf-incremental-leave-updates-reference ()
  ;; The incremental leave path (default) re-resolves references from the
  ;; overlay-derived label map, not a buffer scan: inserting a numbered
  ;; equation above a labelled one bumps an `\eqref' to it.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "intro\n\n\\begin{equation}\\label{eq:b}\nb\n\\end{equation}\n\n"
                "See \\eqref{eq:b}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (should latex-to-svg-frontend-incremental-reconcile) ; default on
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (should (equal (substring-no-properties (overlay-get ref 'display)) "(1)"))
        ;; Insert a numbered equation above eq:b and leave it.
        (goto-char (point-min))
        (insert "\\begin{equation}\na\n\\end{equation}\n\n")
        (goto-char 27)
        (latex-to-svg-frontend--handle-cursor)
        (goto-char (point-max))
        (latex-to-svg-frontend--handle-cursor)
        ;; eq:b is now (2); the reference followed via `--overlay-labels'.
        (should (equal (substring-no-properties (overlay-get ref 'display))
                       "(2)"))))))

(ert-deftest l2sf-incremental-in-place-edit-early-exits ()
  ;; Editing an equation's body without changing its count must not renumber
  ;; (nor recompile) downstream equations: the incremental reconcile stops as
  ;; soon as numbers realign.  We prove it by leaving with a sentinel image:
  ;; only the edited block picks it up; the downstream overlay is untouched.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\nb\n\\end{equation}\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((eq2 (car (last (l2sf-tests--overlays)))))
        (should (string-prefix-p "\\setcounter{equation}{1}%"
                                 (overlay-get eq2 'latex-to-svg-frontend-value)))
        ;; Reveal the first equation, edit its body (count unchanged), leave.
        (goto-char (+ (point-min) 18))         ; inside eq1 (on the "a" line)
        (latex-to-svg-frontend--handle-cursor) ; reveal
        (insert "a")                           ; "a" -> "aa", still consumes 1
        (let ((l2sf-tests--image 'sentinel))
          (goto-char (point-max))
          (latex-to-svg-frontend--handle-cursor)) ; leave -> incremental reconcile
        (let ((ovs (l2sf-tests--overlays)))
          ;; eq1 re-rendered (sentinel); eq2 NOT touched (still fake-image, {1}).
          (should (eq (overlay-get (car ovs) 'display) 'sentinel))
          (should (eq (overlay-get (car (last ovs)) 'display) 'fake-image))
          (should (string-prefix-p
                   "\\setcounter{equation}{1}%"
                   (overlay-get (car (last ovs)) 'latex-to-svg-frontend-value))))))))

(ert-deftest l2sf-incremental-disabled-still-renumbers ()
  ;; With the incremental path off, the leave still renumbers downstream via a
  ;; full `--reconcile' \=-- same observable result.
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n\\begin{equation}\nb\n\\end{equation}\n"
      (setq-local latex-to-svg-frontend-mode t)
      (setq-local latex-to-svg-frontend-incremental-reconcile nil)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (point-min))
      (insert "\\begin{equation}\na\n\\end{equation}\n\n")
      (goto-char 20)
      (latex-to-svg-frontend--handle-cursor)
      (goto-char (point-max))
      (latex-to-svg-frontend--handle-cursor)
      (should (= 2 (length (l2sf-tests--overlays))))
      (should (string-prefix-p
               "\\setcounter{equation}{1}%"
               (overlay-get (car (last (l2sf-tests--overlays)))
                            'latex-to-svg-frontend-value))))))

(ert-deftest l2sf-clean-leave-cancels-redundant-scan ()
  ;; When every pending edit is inside the equation we just left, the
  ;; incremental leave has already brought numbers up to date, so the pending
  ;; whole-buffer catch-up pass is cancelled.
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (point-max))
      (insert "\\begin{equation}\nx=1\n\\end{equation}")
      (goto-char (- (point) 3))                  ; inside the new block
      (latex-to-svg-frontend--handle-cursor)     ; seed last-point inside
      (let ((el (latex-to-svg-frontend--element-at (point))))
        ;; Simulate the edit's after-change over the equation's own span.
        (latex-to-svg-frontend--schedule-reconcile
         (latex-to-svg-frontend--math-begin el)
         (latex-to-svg-frontend--math-end el)))
      (should (timerp latex-to-svg-frontend--reconcile-timer))
      (should latex-to-svg-frontend--dirty)
      (goto-char (point-min))                    ; leave
      (latex-to-svg-frontend--handle-cursor)     ; render + reconcile + maybe-cancel
      (should (null latex-to-svg-frontend--reconcile-timer))
      (should (null latex-to-svg-frontend--dirty)))))

(ert-deftest l2sf-leave-keeps-scan-when-edit-outside ()
  ;; If text also changed outside the left equation (e.g. a paste elsewhere the
  ;; incremental walk cannot see), the pending catch-up pass is kept.
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (point-max))
      (insert "\\begin{equation}\nx=1\n\\end{equation}")
      (goto-char (- (point) 3))
      (latex-to-svg-frontend--handle-cursor)
      ;; Pending change reaches back to the buffer start, outside the equation.
      (latex-to-svg-frontend--schedule-reconcile (point-min) (1+ (point-min)))
      (should (timerp latex-to-svg-frontend--reconcile-timer))
      (goto-char (point-min))
      (latex-to-svg-frontend--handle-cursor)
      (should (timerp latex-to-svg-frontend--reconcile-timer)) ; kept
      (should latex-to-svg-frontend--dirty)
      (latex-to-svg-frontend--cancel-reconcile)))) ; cleanup

(ert-deftest l2sf-no-render-while-inside-equation ()
  ;; While point is still inside a just-typed (complete) equation, nothing is
  ;; compiled — we wait until the cursor leaves.
  (l2sf-tests--with-stub
    (l2sf-tests--md "intro\n\n"
      (setq-local latex-to-svg-frontend-mode t)
      (goto-char (point-max))
      (insert "$x$")
      (goto-char (1+ (point-min)))               ; unrelated spot, seed last-point
      (latex-to-svg-frontend--handle-cursor)
      (goto-char (1- (point-max)))               ; move inside $x$ (between x and $)
      (latex-to-svg-frontend--handle-cursor)
      (should (null (l2sf-tests--overlays)))))) ; still inside -> not rendered

(ert-deftest l2sf-render-replaces-existing-overlay ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (= 1 (length (l2sf-tests--overlays)))))))

;;;; Command

(ert-deftest l2sf-old-command-runs-refresh ()
  ;; `latex-to-svg-frontend' is an obsolete alias: it runs the refresh, which
  ;; renders an equation with no preview.
  (should (eq (indirect-function 'latex-to-svg-frontend)
              (indirect-function 'latex-to-svg-frontend-refresh)))
  (should (get 'latex-to-svg-frontend 'byte-obsolete-info))
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n$a$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (with-suppressed-warnings ((obsolete latex-to-svg-frontend))
        (latex-to-svg-frontend))
      (should (equal (l2sf-tests--values) '("$a$"))))))

(ert-deftest l2sf-org-mode-remaps-org-latex-preview ()
  ;; In an Org buffer with the mode on, `org-latex-preview' is remapped to a
  ;; message, whatever key runs it; with the mode off, Org's own command is
  ;; back.  The Markdown adaptor remaps nothing.
  (l2sf-tests--with-stub
    (with-temp-buffer
      (org-mode)
      (latex-to-svg-for-org-mode 1)
      (should (eq (command-remapping 'org-latex-preview)
                  #'latex-to-svg-for-org-preview-disabled))
      (latex-to-svg-for-org-mode -1)
      (should-not (command-remapping 'org-latex-preview))))
  (should-not (assq 'latex-to-svg-for-markdown-mode minor-mode-map-alist)))

(ert-deftest l2sf-latex-exclusions ()
  ;; The LaTeX adaptor skips the preamble, comments (not an escaped `\%'),
  ;; `\verb' with any delimiter, verbatim and `comment' environments,
  ;; `\iffalse' ... `\fi' (not a commented-out `\iffalse'), and what follows
  ;; `\end{document}'.
  (l2sf-tests--md
      (concat "\\documentclass{article}\n"
              "\\newcommand{\\ket}[1]{$|#1\\rangle$}\n"
              "\\begin{document}\n"
              "Keep $a$. % drop $b$\n"
              "Escaped \\% keep $c$.\n"
              "\\verb|$d$| and \\verb*+$e$+ keep $f$.\n"
              "\\begin{verbatim}\n$g$\n\\end{verbatim}\n"
              "\\begin{comment}\n$h$\n\\end{comment}\n"
              "% \\iffalse\n"
              "Keep $m$.\n"
              "\\iffalse\n$i$\n\\fi\n"
              "Keep $j$.\n"
              "\\end{document}\n"
              "$k$\n")
    (setq-local latex-to-svg-frontend-exclude-function
                #'latex-to-svg-for-latex--exclusions)
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$" "$c$" "$f$" "$m$" "$j$")))))

(ert-deftest l2sf-latex-file-without-document-is-all-body ()
  ;; A chapter file, with no `\begin{document}', has no preamble to skip.
  (l2sf-tests--md "\\section{A}\nKeep $a$.\n"
    (setq-local latex-to-svg-frontend-exclude-function
                #'latex-to-svg-for-latex--exclusions)
    (should (equal (mapcar #'latex-to-svg-frontend--math-value
                           (latex-to-svg-frontend--elements (point-min) (point-max)))
                   '("$a$")))))

(ert-deftest l2sf-latex-mode-setup ()
  ;; The adaptor refuses outside LaTeX buffers.  In `latex-mode' it turns
  ;; the core on, sets the engine to `latex' unless the buffer already has
  ;; a local value, and remaps the preview-latex commands; turning it off
  ;; undoes what it set.
  (l2sf-tests--with-stub
    (with-temp-buffer
      (fundamental-mode)
      (should-error (latex-to-svg-for-latex-mode 1) :type 'user-error)
      (should-not latex-to-svg-for-latex-mode))
    (with-temp-buffer
      (let ((latex-mode-hook nil)) (latex-mode))
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-for-latex-mode 1)
        (should latex-to-svg-frontend-mode)
        (should (local-variable-p 'latex-to-svg-frontend-engine))
        (should (eq latex-to-svg-frontend-engine 'latex))
        (dolist (command '(preview-at-point preview-region preview-buffer
                           preview-document preview-environment preview-section))
          (should (eq (command-remapping command)
                      #'latex-to-svg-for-latex-preview-disabled)))
        (latex-to-svg-for-latex-mode -1)
        (should-not latex-to-svg-frontend-mode)
        (should-not (local-variable-p 'latex-to-svg-frontend-engine))
        (should-not (command-remapping 'preview-at-point))))
    (with-temp-buffer
      (let ((latex-mode-hook nil)) (latex-mode))
      (setq-local latex-to-svg-frontend-engine 'ratex)
      (latex-to-svg-for-latex-mode 1)
      (should (eq latex-to-svg-frontend-engine 'ratex))
      (latex-to-svg-for-latex-mode -1)
      (should (eq latex-to-svg-frontend-engine 'ratex)))))

(ert-deftest l2sf-latex-aux-file-template ()
  ;; Without AUCTeX the `.aux' is next to the file; a template fills `%b'
  ;; with the base name and `%r' with the project root, else the file's
  ;; directory, and a relative result is relative to the file's directory.
  (with-temp-buffer
    (setq buffer-file-name "/p/chapters/paper.tex")
    (let ((project-find-functions nil))
      (let ((latex-to-svg-for-latex-aux-file nil))
        (should (equal (latex-to-svg-for-latex--aux-file) "/p/chapters/paper.aux")))
      (let ((latex-to-svg-for-latex-aux-file "._aux/%b.aux"))
        (should (equal (latex-to-svg-for-latex--aux-file) "/p/chapters/._aux/paper.aux")))
      (let ((latex-to-svg-for-latex-aux-file "%r/build/main.aux"))
        (should (equal (latex-to-svg-for-latex--aux-file) "/p/chapters/build/main.aux"))))
    (let ((project-find-functions (list (lambda (_dir) (cons 'transient "/p/"))))
          (latex-to-svg-for-latex-aux-file "%r/build/main.aux"))
      (should (equal (latex-to-svg-for-latex--aux-file) "/p/build/main.aux")))
    (setq buffer-file-name nil)
    (should-not (latex-to-svg-for-latex--aux-file))))

;; AUCTeX's; declared so the test below binds it dynamically without AUCTeX.
(defvar TeX-output-dir)

(ert-deftest l2sf-latex-aux-file-from-auctex ()
  ;; In `LaTeX-mode' the `.aux' comes from `TeX-master-output-file', whose
  ;; name is relative to the master's directory with `TeX-output-dir' set,
  ;; else to the buffer's.  A template overrides it.
  (with-temp-buffer
    (setq buffer-file-name "/p/chapters/ch1.tex"
          default-directory "/p/chapters/"
          major-mode 'LaTeX-mode)
    (cl-letf (((symbol-function 'TeX-master-directory) (lambda () "/p/")))
      (let ((TeX-output-dir nil))
        (cl-letf (((symbol-function 'TeX-master-output-file)
                   (lambda (_ext) "../main.aux")))
          (should (equal (latex-to-svg-for-latex--aux-file) "/p/main.aux"))))
      (let ((TeX-output-dir "._aux/"))
        (cl-letf (((symbol-function 'TeX-master-output-file)
                   (lambda (_ext) "._aux/main.aux")))
          (should (equal (latex-to-svg-for-latex--aux-file) "/p/._aux/main.aux"))
          (let ((latex-to-svg-for-latex-aux-file "%b.aux"))
            (should (equal (latex-to-svg-for-latex--aux-file)
                           "/p/chapters/ch1.aux"))))))))

(ert-deftest l2sf-latex-read-aux ()
  ;; The number is the first group of `\newlabel''s second argument, in the
  ;; hyperref form and the plain one, with `\relax' removed; cleveref's
  ;; `@cref' entries are skipped; `\@input' of a chapter `.aux' is followed,
  ;; and a cycle stops.  The lines are as LaTeX writes them.
  (let ((dir (make-temp-file "l2sf-aux" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "chapters" dir))
          (with-temp-file (expand-file-name "main.aux" dir)
            (insert "\\relax\n"
                    "\\@input{chapters/ch1.aux}\n"
                    "\\newlabel{sec:plain}{{3}{7}}\n"
                    "\\newlabel{sec:relax}{{\\relax 4.2}{9}}\n"))
          (with-temp-file (expand-file-name "chapters/ch1.aux" dir)
            (insert "\\@input{../main.aux}\n"
                    "\\newlabel{eq:x}{{1.1}{1}{S}{equation.1.1}{}}\n"
                    "\\newlabel{eq:x@cref}{{[equation][1][1]1.1}{[1][1][]1}{}{}{}}\n"))
          (let ((labels (latex-to-svg-for-latex--read-aux
                         (expand-file-name "main.aux" dir)
                         (make-hash-table :test 'equal)))
                (pairs nil))
            (maphash (lambda (k v) (push (cons k v) pairs)) labels)
            (should (equal (sort pairs (lambda (a b) (string< (car a) (car b))))
                           '(("eq:x" . "1.1") ("sec:plain" . "3")
                             ("sec:relax" . "4.2"))))))
      (delete-directory dir t))))

(ert-deftest l2sf-latex-references-follow-the-aux-file ()
  ;; References resolve from the `.aux' file, `??' for a label it lacks and
  ;; for all of them with no `.aux' file.  After the file changes,
  ;; `latex-to-svg-for-latex-update-references' re-resolves them.
  (let* ((dir (make-temp-file "l2sf-aux" t))
         (aux (expand-file-name "paper.aux" dir)))
    (unwind-protect
        (l2sf-tests--with-stub
          (with-temp-buffer
            (insert "See \\ref{sec:b}, \\eqref{eq:a} and \\ref{fig:none}.\n")
            (setq buffer-file-name (expand-file-name "paper.tex" dir))
            (let ((latex-mode-hook nil)) (latex-mode))
            (unwind-protect
                (progn
                  (latex-to-svg-for-latex-mode 1)
                  (sit-for 0.01)
                  (should (equal (l2sf-tests--ref-displays) '("??" "(??)" "??")))
                  (with-temp-file aux
                    (insert "\\newlabel{sec:b}{{2}{3}{B}{section.2}{}}\n"
                            "\\newlabel{eq:a}{{2.1}{3}{B}{equation.2.1}{}}\n"))
                  (latex-to-svg-for-latex-update-references)
                  (should (equal (l2sf-tests--ref-displays) '("2" "(2.1)" "??")))
                  (with-temp-file aux
                    (insert "\\newlabel{sec:b}{{3}{4}{B}{section.3}{}}\n"
                            "\\newlabel{eq:a}{{3.1}{4}{B}{equation.3.1}{}}\n"))
                  ;; Two writes within the file system's time resolution.
                  (set-file-times aux (time-add nil 10))
                  (latex-to-svg-for-latex-update-references)
                  (should (equal (l2sf-tests--ref-displays) '("3" "(3.1)" "??"))))
              (latex-to-svg-for-latex-mode -1)
              (set-buffer-modified-p nil)
              (setq buffer-file-name nil))))
      (delete-directory dir t))))

(ert-deftest l2sf-latex-jump-to-label ()
  ;; A reference to a label no equation defines jumps to its `\label'
  ;; elsewhere in the buffer (not one in a comment); failing that, it asks
  ;; xref with point on the label's name, unless the backend is etags
  ;; (which would prompt for a TAGS file); failing that, it is an error.
  (l2sf-tests--with-stub
    (with-temp-buffer
      (insert "% \\label{sec:b}\nSee \\ref{sec:b} and \\ref{sec:far}.\n\n"
              "\\section{B}\\label{sec:b}\n")
      (let ((latex-mode-hook nil)) (latex-mode))
      (latex-to-svg-for-latex-mode 1)
      (let* ((refs (seq-filter (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                               (l2sf-tests--overlays)))
             (target (save-excursion (goto-char (point-max))
                                     (search-backward "\\label{sec:b}")))
             (backend nil)
             (asked nil))
        (cl-letf (((symbol-function 'xref-find-backend) (lambda () backend))
                  ((symbol-function 'xref-backend-identifier-at-point)
                   (lambda (_backend) (buffer-substring (point) (+ (point) 7))))
                  ((symbol-function 'xref-find-definitions)
                   (lambda (identifier) (push identifier asked))))
          (goto-char (overlay-start (car refs)))
          (latex-to-svg-frontend-goto-reference)
          (should (= (point) target))
          (dolist (b '(nil etags tex-etags))
            (setq backend b)
            (goto-char (overlay-start (cadr refs)))
            (should-error (latex-to-svg-frontend-goto-reference) :type 'user-error))
          (should-not asked)
          (setq backend 'eglot)
          (goto-char (overlay-start (cadr refs)))
          (latex-to-svg-frontend-goto-reference)
          (should (equal asked '("sec:far"))))
        (latex-to-svg-for-latex-mode -1)))))

(ert-deftest l2sf-latex-reads-latexs-aux-files ()
  ;; The `.aux' files LaTeX wrote for the fixture book: every label comes
  ;; out with its printed number, from both chapters' `.aux' files.
  (let ((labels (latex-to-svg-for-latex--read-aux
                 (expand-file-name "main.aux" l2sf-tests--book)
                 (make-hash-table :test 'equal)))
        (pairs nil))
    (maphash (lambda (k v) (push (cons k v) pairs)) labels)
    (should (equal (sort pairs (lambda (a b) (string< (car a) (car b))))
                   '(("ch:one" . "1") ("eq:a" . "2.1") ("eq:b" . "2.2")
                     ("eq:x" . "1.1") ("fig:c" . "1.1") ("sec:s" . "1.1"))))))

(defmacro l2sf-tests--visit-book (file &rest body)
  "Visit FILE of the fixture book in `latex-mode' with the adaptor on; run BODY.
The backend must be stubbed.  The buffer is killed afterwards, with any
other buffer BODY opened."
  (declare (indent 1) (debug t))
  `(let ((before (buffer-list))
         (buffer (let ((latex-mode-hook nil)
                       (enable-local-variables nil))
                   (find-file-noselect (expand-file-name ,file l2sf-tests--book)))))
     (unwind-protect
         (with-current-buffer buffer
           (let ((latex-mode-hook nil)) (latex-mode))
           (latex-to-svg-for-latex-mode 1)
           (sit-for 0.01)
           ,@body)
       (dolist (b (buffer-list))
         (unless (memq b before) (kill-buffer b))))))

(ert-deftest l2sf-latex-book-references ()
  ;; A chapter of the fixture book, with the template pointing at the main
  ;; `.aux' file: its `\eqref' to an equation of the other chapter shows
  ;; the number LaTeX printed.
  (l2sf-tests--with-stub
    (let ((latex-to-svg-for-latex-aux-file "../main.aux"))
      (l2sf-tests--visit-book "chapters/ch2.tex"
        (should (equal (l2sf-tests--ref-displays) '("(1.1)")))))))

;; A stand-in for eglot's xref backend: it answers `xref-find-definitions'
;; with a location in another file, as texlab does.  The backend is only
;; active in a buffer that puts `l2sf-tests--xref' in its
;; `xref-backend-functions'.
(defun l2sf-tests--xref () 'l2sf-tests)

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql 'l2sf-tests)))
  (save-excursion
    (let ((b (point)))
      (skip-chars-forward "^}")
      (buffer-substring-no-properties b (point)))))

(cl-defmethod xref-backend-definitions ((_backend (eql 'l2sf-tests)) label)
  (let ((file (expand-file-name "chapters/ch1.tex" l2sf-tests--book)))
    (with-temp-buffer
      (insert-file-contents file)
      (search-forward (format "\\label{%s}" label))
      (list (xref-make label (xref-make-file-location
                              file (line-number-at-pos)
                              (- (match-beginning 0) (line-beginning-position))))))))

(ert-deftest l2sf-latex-book-jump-through-xref ()
  ;; A reference to a label in another chapter goes through xref: the real
  ;; `xref-find-definitions', with a backend that answers as eglot running
  ;; texlab does, opens the other chapter at the `\label'.
  (require 'xref)
  (l2sf-tests--with-stub
    (let ((latex-to-svg-for-latex-aux-file "../main.aux"))
      (l2sf-tests--visit-book "chapters/ch2.tex"
        (add-hook 'xref-backend-functions #'l2sf-tests--xref nil t)
        (goto-char (overlay-start
                    (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                              (l2sf-tests--overlays))))
        (latex-to-svg-frontend-goto-reference)
        (should (equal (file-name-nondirectory buffer-file-name) "ch1.tex"))
        (should (looking-at-p (regexp-quote "\\label{eq:x}")))))))

(ert-deftest l2sf-latex-book-with-auctex ()
  ;; With the real AUCTeX: a chapter whose `TeX-master' is the main file
  ;; finds the main `.aux' file, next to it or in `TeX-output-dir', and its
  ;; references resolve from it.  Skipped without AUCTeX (see `AUCTEX_DIR').
  (skip-unless (and (require 'tex-site nil t) (require 'latex nil t)))
  (l2sf-tests--with-stub
    (let ((before (buffer-list))
          (buffer (let ((enable-local-variables nil))
                    (find-file-noselect
                     (expand-file-name "chapters/ch2.tex" l2sf-tests--book)))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((LaTeX-mode-hook nil)) (LaTeX-mode))
            (setq-local TeX-master "../main")
            (dolist (case `((nil . ,(expand-file-name "main.aux" l2sf-tests--book))
                            ("._aux/" . ,(expand-file-name "._aux/main.aux"
                                                           l2sf-tests--book))))
              (setq-local TeX-output-dir (car case))
              (should (equal (latex-to-svg-for-latex--aux-file) (cdr case))))
            (setq-local TeX-output-dir nil)
            (latex-to-svg-for-latex-mode 1)
            (sit-for 0.01)
            (should (equal (l2sf-tests--ref-displays) '("(1.1)"))))
        (dolist (b (buffer-list))
          (unless (memq b before) (kill-buffer b)))))))

(ert-deftest l2sf-mode-binds-no-key ()
  ;; The core mode binds no key, so it shadows none of the markup mode's own
  ;; (`markdown-mode' binds C-c C-x C-l).
  (should (null (cdr latex-to-svg-frontend-mode-map))))

(ert-deftest l2sf-clear-command ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ $b$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (= 2 (length (l2sf-tests--overlays))))
      (latex-to-svg-frontend-clear)
      (should (null (l2sf-tests--overlays))))))

(ert-deftest l2sf-refresh-prefix-recompiles ()
  ;; A prefix argument recompiles the buffer's previews, bypassing the cache.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((l2sf-tests--image 'fresh))
        (latex-to-svg-frontend-refresh nil '(4)))
      (should (equal l2sf-tests--invalidated '("$a$")))
      (let ((ovs (l2sf-tests--overlays)))
        (should (= 1 (length ovs)))
        (should (eq (overlay-get (car ovs) 'display) 'fresh))))))

(ert-deftest l2sf-regenerate-obsolete-still-works ()
  ;; The obsolete command still recompiles the region or the buffer.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (with-suppressed-warnings ((obsolete latex-to-svg-frontend-regenerate))
        (latex-to-svg-frontend-regenerate))
      (should (equal l2sf-tests--invalidated '("$a$"))))))

(ert-deftest l2sf-refresh-renders-missing-and-changed ()
  ;; A refresh renders an equation with no preview, renders again one whose
  ;; engine changed, and leaves the equation containing point alone.
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n$a$\n\n$b$\n\n$c$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-element
       (car (latex-to-svg-frontend--elements (point-min) (point-max))))
      (should (equal (l2sf-tests--values) '("$a$")))
      (goto-char (point-min))
      (search-forward "$c")
      (latex-to-svg-frontend-refresh)
      (should (equal (l2sf-tests--values) '("$a$" "$b$")))
      ;; A changed engine: both previews are rendered again with it.
      (setq l2sf-tests--calls nil)
      (setq-local latex-to-svg-frontend-engine 'ratex)
      (latex-to-svg-frontend-refresh)
      (should (equal (sort (delete-dups
                            (mapcar #'car
                                    (seq-filter (lambda (c) (eq (cdr c) 'ratex))
                                                l2sf-tests--calls)))
                           #'string<)
                     '("$a$" "$b$")))
      (should (cl-every (lambda (o) (eq (overlay-get o 'latex-to-svg-frontend-engine)
                                        'ratex))
                        (l2sf-tests--overlays))))))

(ert-deftest l2sf-option-watcher-updates-buffers ()
  ;; Setting a watched option updates the previews on its own: a buffer-local
  ;; value updates that buffer, a default value every buffer, and a
  ;; let-binding nothing.  The update runs from a timer; run it here directly.
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n$a$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (unwind-protect
          (progn
            (setq-local latex-to-svg-frontend-engine 'ratex)
            (should (equal latex-to-svg-frontend--option-buffers
                           (list (current-buffer))))
            (should (timerp latex-to-svg-frontend--option-timer))
            (latex-to-svg-frontend--update-after-option)
            (should (eq (overlay-get (car (l2sf-tests--overlays))
                                     'latex-to-svg-frontend-engine)
                        'ratex))
            (should-not latex-to-svg-frontend--option-buffers)
            (let ((latex-to-svg-frontend-foreground-color nil))
              (should-not latex-to-svg-frontend--option-buffers)
              ;; `setq' of a variable with no local value sets its default.
              (setq latex-to-svg-frontend-foreground-color "red")
              (should-not latex-to-svg-frontend--option-buffers)
              (should (equal latex-to-svg-frontend--option-defaults
                             '(latex-to-svg-frontend-foreground-color)))))
        (when (timerp latex-to-svg-frontend--option-timer)
          (cancel-timer latex-to-svg-frontend--option-timer))
        (setq latex-to-svg-frontend--option-timer nil
              latex-to-svg-frontend--option-buffers nil
              latex-to-svg-frontend--option-defaults nil)))))

(ert-deftest l2sf-backend-options-are-watched ()
  ;; The backend's options in the cache key that a project sets in
  ;; `.dir-locals.el' (the three preambles, the width of numbered
  ;; equations, RaTeX's macros) update the previews like this package's
  ;; own options.
  (dolist (option '(latex-to-svg-backend-preamble
                    latex-to-svg-backend-appended-preamble
                    latex-to-svg-backend-preamble-not-precompiled
                    latex-to-svg-backend-line-width
                    latex-to-svg-backend-ratex-macros))
    (should (memq #'latex-to-svg-frontend--option-changed
                  (get-variable-watchers option)))))

(ert-deftest l2sf-option-default-skips-buffers-with-own-value ()
  ;; A change of `latex-to-svg-backend-preamble-not-precompiled''s default updates the
  ;; buffers that use the default, not a buffer with its own value (set by
  ;; its `.dir-locals.el').  A buffer-local change updates that buffer.
  (l2sf-tests--with-stub
    (let ((updated nil)
          (own (generate-new-buffer " l2sf-own"))
          (uses-default (generate-new-buffer " l2sf-default")))
      (unwind-protect
          (cl-letf (((symbol-function 'latex-to-svg-frontend--update-buffer)
                     (lambda (buf) (push buf updated))))
            (dolist (buf (list own uses-default))
              (with-current-buffer buf (setq-local latex-to-svg-frontend-mode t)))
            (with-current-buffer own
              (setq-local latex-to-svg-backend-preamble-not-precompiled "\\input{m}"))
            (should (equal latex-to-svg-frontend--option-buffers (list own)))
            (latex-to-svg-frontend--update-after-option)
            (should (equal updated (list own)))
            (setq updated nil)
            (let ((latex-to-svg-backend-preamble-not-precompiled ""))
              (setq latex-to-svg-backend-preamble-not-precompiled "\\input{g}")
              (latex-to-svg-frontend--update-after-option)
              (should (equal updated (list uses-default)))))
        (when (timerp latex-to-svg-frontend--option-timer)
          (cancel-timer latex-to-svg-frontend--option-timer))
        (setq latex-to-svg-frontend--option-timer nil
              latex-to-svg-frontend--option-buffers nil
              latex-to-svg-frontend--option-defaults nil)
        (kill-buffer own)
        (kill-buffer uses-default)))))

(ert-deftest l2sf-appearance-refresh-only-redraws ()
  ;; The automatic refresh after a theme or zoom change only redraws what is
  ;; on screen: it renders no new equation.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n\n$b$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-element
       (car (latex-to-svg-frontend--elements (point-min) (point-max))))
      (goto-char (point-max))
      (setq l2sf-tests--appearance '("#fff" "#000" 28))
      (latex-to-svg-frontend--refresh-if-changed)
      (should (equal (l2sf-tests--values) '("$a$"))))))

;;;; Minor mode

(ert-deftest l2sf-font-height-reports-unmeasurable-font ()
  ;; A font the frame cannot measure leaves the height unknown, so the backend
  ;; defers sizing -- but it is reported, once per buffer, never swallowed.
  (let ((warnings 0))
    (with-temp-buffer
      (cl-letf (((symbol-function 'get-buffer-window)
                 (lambda (&rest _) (selected-window)))
                ((symbol-function 'window-frame) (lambda (&rest _) (selected-frame)))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'default-font-height)
                 (lambda (&rest _) (signal 'wrong-type-argument (list 'arrayp nil))))
                ((symbol-function 'display-warning)
                 (lambda (&rest _) (cl-incf warnings))))
        (should-not (latex-to-svg-frontend--font-height))
        (should-not (latex-to-svg-frontend--font-height))
        ;; One diagnosis for the buffer, not one per equation.
        (should (= 1 warnings))))))

(ert-deftest l2sf-markdown-mode-renders-and-clears ()
  ;; The Markdown adaptor mode installs the protocol and turns on the core.
  (skip-unless (fboundp 'markdown-ts-mode))
  (l2sf-tests--with-stub
    (with-temp-buffer
      (let ((markdown-ts-mode-hook nil))
        (ignore-errors (markdown-ts-mode)))
      (skip-unless (derived-mode-p 'markdown-ts-mode))
      (insert "$a$ \\[b\\]\n")
      (latex-to-svg-for-markdown-mode 1)
      (should latex-to-svg-frontend-mode)          ; core enabled by the adaptor
      (should (= 2 (length (l2sf-tests--overlays))))
      (latex-to-svg-for-markdown-mode -1)
      (should-not latex-to-svg-frontend-mode)
      (should (null (l2sf-tests--overlays))))))

(ert-deftest l2sf-markdown-mode-refuses-non-markdown ()
  ;; The adaptor gates on the major mode (the core itself does not).
  (with-temp-buffer
    (fundamental-mode)
    (should-error (latex-to-svg-for-markdown-mode 1))
    (should-not latex-to-svg-for-markdown-mode)))

;;;; Refresh

(ert-deftest l2sf-refresh-updates-image ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display) 'fake-image))
      (let ((l2sf-tests--image 'retinted-image))
        (latex-to-svg-frontend-refresh))
      (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display) 'retinted-image)))))

(ert-deftest l2sf-refresh-compiles-a-cache-miss ()
  ;; After a change of a backend option in the cache key (the preamble),
  ;; the refresh finds no picture: it passes a callback and the equation's
  ;; `:metadata', and the callback installs the compiled picture.  A
  ;; callback for an overlay deleted in the meantime does nothing.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}\nx\n\\end{equation}\n\n$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((callbacks nil)
            (metadata nil))
        (cl-letf (((symbol-function 'latex-to-svg-backend)
                   (lambda (_latex &rest args)
                     (push (plist-get args :callback) callbacks)
                     (push (plist-get args :metadata) metadata)
                     nil)))
          (latex-to-svg-frontend-refresh))
        (should (= (length callbacks) 2))
        (should (seq-every-p #'functionp callbacks))
        (should (equal (sort (delq nil metadata) #'<) '(1)))
        (dolist (ov (l2sf-tests--overlays))
          (should (eq (overlay-get ov 'display) 'fake-image)))
        (delete-overlay (car (last (l2sf-tests--overlays))))
        (let ((l2sf-tests--image 'compiled))
          (mapc #'funcall callbacks))
        (should (equal (mapcar (lambda (ov) (overlay-get ov 'display))
                               (l2sf-tests--overlays))
                       '(compiled)))))))

(ert-deftest l2sf-refresh-if-changed-gated-on-appearance ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((l2sf-tests--image 'should-not-apply))
        (latex-to-svg-frontend--refresh-if-changed)
        (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display) 'fake-image)))
      (setq l2sf-tests--appearance '("#fff" "#000" 28))
      (let ((l2sf-tests--image 'applied))
        (latex-to-svg-frontend--refresh-if-changed)
        (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display) 'applied))))))

(ert-deftest l2sf-on-appearance-change-refreshes-changed-buffers ()
  ;; A frame font change is global: the handler sweeps every mode buffer,
  ;; but still only refreshes the ones whose appearance actually changed.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((l2sf-tests--image 'should-not-apply))
        (latex-to-svg-frontend-on-appearance-change)
        (sit-for 0.1)
        (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display)
                    'fake-image)))
      ;; Same font, bigger frame font -> new measured height.
      (setq l2sf-tests--appearance '("#000" "#fff" 40))
      (let ((l2sf-tests--image 'rescaled))
        (latex-to-svg-frontend-on-appearance-change)
        (sit-for 0.1)
        (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display)
                    'rescaled))))))

(ert-deftest l2sf-on-appearance-change-skips-buffers-without-the-mode ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (setq-local latex-to-svg-frontend-mode nil)
      (setq l2sf-tests--appearance '("#000" "#fff" 40))
      (let ((l2sf-tests--image 'should-not-apply))
        (latex-to-svg-frontend-on-appearance-change)
        (sit-for 0.1)
        (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display)
                    'fake-image))))))

(ert-deftest l2sf-first-render-sees-dir-locals ()
  ;; Emacs runs a major mode's hooks before it applies `.dir-locals.el'.
  ;; In a buffer visiting a file the first render runs from a timer, so
  ;; the backend sees the preamble `.dir-locals.el' sets.
  (let* ((dir (make-temp-file "l2sf-dir-locals" t))
         (file (expand-file-name "a.txt" dir))
         (seen 'none)
         (buffer nil))
    (unwind-protect
        (l2sf-tests--with-stub
          (with-temp-file (expand-file-name ".dir-locals.el" dir)
            (prin1 '((text-mode
                      . ((latex-to-svg-backend-preamble-not-precompiled . "\\input{m}"))))
                   (current-buffer)))
          (with-temp-file file (insert "$a$\n"))
          (cl-letf (((symbol-function 'latex-to-svg-backend)
                     (lambda (_latex &rest _args)
                       (setq seen latex-to-svg-backend-preamble-not-precompiled)
                       l2sf-tests--image)))
            (let ((enable-local-variables :all)
                  (text-mode-hook (list #'latex-to-svg-frontend-mode)))
              (setq buffer (find-file-noselect file))
              (with-current-buffer buffer
                (should latex-to-svg-frontend-mode)
                (should (eq seen 'none))
                (should-not (l2sf-tests--overlays))
                (sit-for 0.01)
                (should (equal seen "\\input{m}"))
                (should (l2sf-tests--overlays))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest l2sf-major-mode-change-clears-previews ()
  ;; `normal-mode' (also run by `revert-buffer') changes the major mode,
  ;; which keeps overlays.  The mode clears its previews first, so the
  ;; mode hook renders again: the new picture when there is one, none when
  ;; the equation no longer compiles.
  (let* ((dir (make-temp-file "l2sf-normal-mode" t))
         (file (expand-file-name "a.txt" dir))
         (buffer nil))
    (unwind-protect
        (l2sf-tests--with-stub
          (with-temp-file file (insert "$a$\n"))
          (let ((text-mode-hook (list #'latex-to-svg-frontend-mode))
                (displayed (lambda ()
                             (mapcar (lambda (ov) (overlay-get ov 'display))
                                     (l2sf-tests--overlays)))))
            (setq buffer (find-file-noselect file))
            (with-current-buffer buffer
              (sit-for 0.01)
              (should (equal (funcall displayed) '(fake-image)))
              (let ((l2sf-tests--image 'new))
                (normal-mode)
                (sit-for 0.01)
                (should latex-to-svg-frontend-mode)
                (should (equal (funcall displayed) '(new))))
              (let ((l2sf-tests--image nil))
                (normal-mode)
                (sit-for 0.01)
                (should-not (funcall displayed))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest l2sf-mode-off-cancels-first-render ()
  ;; Turning the mode off before the scheduled first render cancels it.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (setq buffer-file-name (expand-file-name "l2sf-none.txt"
                                               temporary-file-directory))
      (unwind-protect
          (progn
            (latex-to-svg-frontend-mode 1)
            (should (timerp latex-to-svg-frontend--initial-render-timer))
            (latex-to-svg-frontend-mode -1)
            (should-not latex-to-svg-frontend--initial-render-timer)
            (sit-for 0.01)
            (should-not (l2sf-tests--overlays)))
        (set-buffer-modified-p nil)
        (setq buffer-file-name nil)))))

(ert-deftest l2sf-installs-no-global-hooks ()
  ;; Policy: theme / frame-font tracking is opt-in.  Loading the package
  ;; (and enabling the mode) must never touch a global hook.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend-mode 1)
      (should-not (memq 'latex-to-svg-frontend-on-appearance-change
                        (default-value 'after-setting-font-hook)))
      (should-not (memq 'latex-to-svg-frontend-on-appearance-change
                        (default-value 'enable-theme-functions)))
      (should-not (memq 'latex-to-svg-frontend--maybe-refresh
                        (default-value 'window-buffer-change-functions))))))

;;;; Numbering

(ert-deftest l2sf-counts-single-environments ()
  (should (= 1 (latex-to-svg-frontend--count-numbered-equations
                "\\begin{equation}\nx=1\n\\end{equation}")))
  (should (= 0 (latex-to-svg-frontend--count-numbered-equations
                "\\begin{equation*}\nx=1\n\\end{equation*}")))
  (should (= 0 (latex-to-svg-frontend--count-numbered-equations
                "\\begin{equation}\nx=1\\nonumber\n\\end{equation}"))))

(ert-deftest l2sf-multline-consumes-one ()
  (should (= 1 (latex-to-svg-frontend--count-numbered-equations
                "\\begin{multline}\na\\\\b\\\\c\n\\end{multline}"))))

(ert-deftest l2sf-counts-multi-rows ()
  (should (= 3 (latex-to-svg-frontend--count-numbered-equations
                "\\begin{align}\na&=b\\\\\nc&=d\\\\\ne&=f\n\\end{align}")))
  (should (= 2 (latex-to-svg-frontend--count-numbered-equations
                "\\begin{align}\na&=b\\\\\nc&=d\\nonumber\\\\\ne&=f\n\\end{align}"))))

(ert-deftest l2sf-nested-rows-not-counted ()
  (should (= 2 (latex-to-svg-frontend--count-numbered-equations
                (concat "\\begin{align}\n"
                        "x&=\\begin{pmatrix}a\\\\b\\end{pmatrix}\\\\\n"
                        "y&=2\n"
                        "\\end{align}")))))

(ert-deftest l2sf-numbering-table-threads-offsets ()
  (l2sf-tests--md
      (concat "\\begin{equation}\na\n\\end{equation}\n\n"
              "\\begin{align}\nb&=1\\\\\nc&=2\n\\end{align}\n\n"
              "\\begin{equation}\nd\n\\end{equation}\n")
    (let* ((table (latex-to-svg-frontend--numbering-table))
           (offsets (mapcar (lambda (el)
                              (gethash (latex-to-svg-frontend--math-begin el) table))
                            (latex-to-svg-frontend--environments))))
      (should (equal offsets '(0 1 3))))))

(ert-deftest l2sf-bakes-setcounter-into-overlay ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "$a$\n\n\\begin{equation}\nx\n\\end{equation}\n\n"
                "\\begin{equation}\ny\n\\end{equation}\n")
      (let ((latex-to-svg-frontend-number-equations t))
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
      (let ((values (l2sf-tests--values)))
        (should (equal (nth 0 values) "$a$"))
        (should (string-prefix-p "\\setcounter{equation}{0}%\n\\begin{equation}"
                                 (nth 1 values)))
        (should (string-prefix-p "\\setcounter{equation}{1}%\n\\begin{equation}"
                                 (nth 2 values)))))))

(ert-deftest l2sf-help-echo-is-plain-source ()
  ;; Emacs shows a `help-echo' string after `substitute-command-keys', so
  ;; that is what the user reads: the engine, then the source as written,
  ;; with no `\setcounter' prefix.  Unquoted, `\[' would start a key
  ;; reference and `\[E=mc^2\]' would read "M-x E=mc^2\".
  (l2sf-tests--with-stub
    (dolist (source '("\\begin{equation}\nx\n\\end{equation}"
                      "\\[\nE=mc^2\n\\]"
                      "$\\{ x \\}$"
                      "$f`(x)$"))
      (l2sf-tests--md (concat source "\n")
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (let ((ov (car (l2sf-tests--overlays))))
          (should (equal (substitute-command-keys (overlay-get ov 'help-echo))
                         (concat "Typeset with LaTeX: " source))))))))

(ert-deftest l2sf-numbering-can-be-disabled ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}\nx\n\\end{equation}\n"
      (let ((latex-to-svg-frontend-number-equations nil))
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
      (let ((ov (car (l2sf-tests--overlays))))
        (should (equal (overlay-get ov 'latex-to-svg-frontend-value)
                       "\\begin{equation}\nx\n\\end{equation}"))))))

(ert-deftest l2sf-regenerate-invalidates-numbered-value ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}\nx\n\\end{equation}\n"
      (let ((latex-to-svg-frontend-number-equations t))
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (latex-to-svg-frontend-refresh nil '(4)))
      (should (equal l2sf-tests--invalidated
                     '("\\setcounter{equation}{0}%\n\\begin{equation}\nx\n\\end{equation}\\typeout{L2S=\\arabic{equation}}%\n"))))))

(ert-deftest l2sf-reconcile-updates-downstream ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\nb\n\\end{equation}\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (string-prefix-p
               "\\setcounter{equation}{1}%"
               (overlay-get (nth 1 (l2sf-tests--overlays))
                            'latex-to-svg-frontend-value)))
      (goto-char (point-min))
      (search-forward "\\begin{equation}") (backward-char 1) (insert "*")
      (search-forward "\\end{equation}") (backward-char 1) (insert "*")
      (latex-to-svg-frontend--reconcile)
      (let ((ovs (l2sf-tests--overlays)))
        (should (string-prefix-p
                 "\\setcounter{equation}{0}%"
                 (overlay-get (car (last ovs)) 'latex-to-svg-frontend-value)))))))

(ert-deftest l2sf-scan-numbering-accepts-precomputed-environments ()
  ;; Passing a pre-computed environment list (so one scan feeds both the
  ;; reconcile counter threading and the reference re-resolution) must yield
  ;; the exact same LABELS map as a fresh internal scan.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\n\\label{a}\nx\n\\end{equation}\n\n"
                "\\begin{equation}\n\\label{b}\ny\n\\end{equation}\n")
      (setq-local latex-to-svg-frontend-mode t)
      (let* ((envs (latex-to-svg-frontend--environments))
             (fresh (cdr (latex-to-svg-frontend--scan-numbering)))
             (shared (cdr (latex-to-svg-frontend--scan-numbering envs))))
        (should (= 1 (gethash "a" shared)))
        (should (= 2 (gethash "b" shared)))
        (should (equal (gethash "a" fresh) (gethash "a" shared)))
        (should (equal (gethash "b" fresh) (gethash "b" shared)))))))

(ert-deftest l2sf-reconcile-uses-ground-truth-consumed ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\nb\n\\end{equation}\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (overlay-put (nth 0 (l2sf-tests--overlays))
                   'latex-to-svg-frontend-enums '(1 . 2))
      (latex-to-svg-frontend--reconcile)
      (should (string-prefix-p
               "\\setcounter{equation}{2}%"
               (overlay-get (nth 1 (l2sf-tests--overlays))
                            'latex-to-svg-frontend-value))))))

;;;; RaTeX engine

(ert-deftest l2sf-ratex-tags-equation ()
  ;; With `ratex', a numbered `equation' carries its number as a `\tag'
  ;; before `\end', with no `\setcounter' prefix and no `\typeout' probe.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\nx\n\\end{equation}\n\n"
                "\\begin{equation}\ny\n\\end{equation}\n")
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
      (should (equal (l2sf-tests--values)
                     '("\\begin{equation}\nx\n\\tag{1}\\end{equation}"
                       "\\begin{equation}\ny\n\\tag{2}\\end{equation}")))
      (should (eq (plist-get l2sf-tests--last-args :engine) 'ratex)))))

(ert-deftest l2sf-ratex-suppressed-equation-untagged ()
  ;; A single-equation block with `\notag' takes no number, so it gets no tag
  ;; (RaTeX rejects `\tag' together with `\notag').
  (should (equal (latex-to-svg-frontend--tagged-value
                  4 "\\begin{equation}\nx \\notag\n\\end{equation}")
                 "\\begin{equation}\nx \\notag\n\\end{equation}")))

(ert-deftest l2sf-ratex-tags-align-rows ()
  ;; Each numbered row gets the next number before its `\\\\'; the `\notag'
  ;; row gets none.
  (should (equal (latex-to-svg-frontend--tagged-value
                  1 (concat "\\begin{align}\na &= 1 \\\\\n"
                            "b &= 2 \\notag \\\\\nc &= 3\n\\end{align}"))
                 (concat "\\begin{align}\na &= 1 \\tag{2}\\\\\n"
                         "b &= 2 \\notag \\\\\nc &= 3\n\\tag{3}\\end{align}"))))

(ert-deftest l2sf-ratex-keeps-user-tag ()
  ;; A row that already has `\tag{A}' is left alone (a second tag is a RaTeX
  ;; error), and the next row takes the next number.
  (should (equal (latex-to-svg-frontend--tagged-value
                  0 "\\begin{align}\na \\tag{A} \\\\\nb\n\\end{align}")
                 "\\begin{align}\na \\tag{A} \\\\\nb\n\\tag{1}\\end{align}")))

(ert-deftest l2sf-ratex-nested-environment-one-tag ()
  ;; The `\\\\' inside a nested `cases' does not end a row, so the row gets
  ;; one tag, after the `cases'.
  (should (equal (latex-to-svg-frontend--tagged-value
                  0 (concat "\\begin{align}\n"
                            "f &= \\begin{cases} 1 \\\\ 0 \\end{cases} \\\\\n"
                            "g &= 2\n\\end{align}"))
                 (concat "\\begin{align}\n"
                         "f &= \\begin{cases} 1 \\\\ 0 \\end{cases} \\tag{1}\\\\\n"
                         "g &= 2\n\\tag{2}\\end{align}"))))

(ert-deftest l2sf-ratex-trailing-break-tags-empty-row ()
  ;; A trailing `\\\\' leaves an empty last row.  `--count-multi-rows' counts
  ;; it, as LaTeX does, so it is tagged too and the two engines agree.
  (let ((source "\\begin{align}\na \\\\\nb \\\\\n\\end{align}"))
    (should (= (latex-to-svg-frontend--count-numbered-equations source) 3))
    (should (equal (latex-to-svg-frontend--tagged-value 0 source)
                   (concat "\\begin{align}\na \\tag{1}\\\\\n"
                           "b \\tag{2}\\\\\n\\tag{3}\\end{align}")))))

(ert-deftest l2sf-ratex-removes-labels-keeps-source ()
  ;; RaTeX has no `\label': it is removed from the value sent to the backend,
  ;; kept in the overlay's source, and `\eqref' still resolves from it.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "See $\\eqref{eq:a}$.\n")
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
      (let* ((ovs (l2sf-tests--overlays))
             (eq-ov (nth 0 ovs))
             (ref-ov (nth 1 ovs)))
        (should (equal (overlay-get eq-ov 'latex-to-svg-frontend-value)
                       "\\begin{equation}\nx\n\\tag{1}\\end{equation}"))
        (should (equal (overlay-get eq-ov 'latex-to-svg-frontend-source)
                       "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}"))
        (should (equal (overlay-get ref-ov 'latex-to-svg-frontend-ref-display)
                       "(1)"))))))

(ert-deftest l2sf-ratex-unnumbered-unchanged ()
  ;; Starred environments and `\[…\]' take no number: their value is the
  ;; source, untouched.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{align*}\na \\\\\nb\n\\end{align*}\n\n\\[x\\]\n"
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
      (should (equal (l2sf-tests--values)
                     '("\\begin{align*}\na \\\\\nb\n\\end{align*}" "\\[x\\]"))))))

(ert-deftest l2sf-latex-engine-value-unchanged ()
  ;; The default engine keeps today's value byte for byte (labels included),
  ;; so no LaTeX user's cache is invalidated, and passes `:engine latex'.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}\\label{a}\nx\n\\end{equation}\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (equal (l2sf-tests--values)
                     '("\\setcounter{equation}{0}%\n\\begin{equation}\\label{a}\nx\n\\end{equation}\\typeout{L2S=\\arabic{equation}}%\n")))
      (should (eq (plist-get l2sf-tests--last-args :engine) 'latex)))))

(ert-deftest l2sf-engine-reaches-every-backend-call ()
  ;; `latex-to-svg-backend', `-metadata' and `-invalidate' all receive the
  ;; engine, and a refresh uses the one recorded on the overlay, not the
  ;; option's current value.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}\nx\n\\end{equation}\n"
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (eq (plist-get l2sf-tests--last-args :engine) 'ratex))
        (should (equal l2sf-tests--metadata-engines '(ratex)))
        (should (eq (overlay-get (car (l2sf-tests--overlays))
                                 'latex-to-svg-frontend-engine)
                    'ratex))
        (let ((latex-to-svg-frontend-fallback nil))
          (latex-to-svg-frontend-refresh nil '(4)))
        (should (equal l2sf-tests--invalidated-engines '(ratex))))
      ;; A redraw (theme, zoom) uses the engine recorded on the overlay.
      (setq l2sf-tests--last-args nil)
      (let ((latex-to-svg-frontend-engine 'latex))
        (latex-to-svg-frontend--refresh-buffer (current-buffer)))
      (should (eq (plist-get l2sf-tests--last-args :engine) 'ratex)))))

(ert-deftest l2sf-ratex-reconcile-retags-downstream ()
  ;; Renumbering after an edit rebuilds the tagged value, not a `\setcounter'.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\nb\n\\end{equation}\n")
      (setq-local latex-to-svg-frontend-mode t)
      (setq-local latex-to-svg-frontend-engine 'ratex)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (point-min))
      (search-forward "\\begin{equation}") (backward-char 1) (insert "*")
      (search-forward "\\end{equation}") (backward-char 1) (insert "*")
      (latex-to-svg-frontend--reconcile)
      (should (equal (overlay-get (car (last (l2sf-tests--overlays)))
                                  'latex-to-svg-frontend-value)
                     "\\begin{equation}\nb\n\\tag{1}\\end{equation}")))))

;;;; Per-equation cookies

(ert-deftest l2sf-cookie-forms ()
  ;; Each form the hand-over lists selects the right engine: on the opener
  ;; line or alone on the next line, with or without `latex-to-svg:', with
  ;; blanks around each part, after an environment's arguments.
  (l2sf-tests--with-stub
    (dolist (case '(("\\[% engine=skip\nx\\]" . skip)
                    ("\\[\n% engine=none\nx=1\n\\]" . skip)
                    ("\\begin{align}% latex-to-svg: engine = tex\na\n\\end{align}" . latex)
                    ("\\begin{alignat}{2}  %latex-to-svg:engine=latex\na\n\\end{alignat}" . latex)
                    ("$$ % engine=ratex\nx$$" . ratex)))
      (should (eq (latex-to-svg-frontend--engine-for (car case)) (cdr case))))))

(ert-deftest l2sf-cookie-position-rule ()
  ;; Only a comment before any math is a cookie: one further down the body,
  ;; after math on the opener line, after `\%', or in inline math is not.
  (l2sf-tests--with-stub
    (let ((latex-to-svg-frontend-engine 'latex))
      (dolist (source '("\\begin{align}\na \\\\% engine=ratex\n\\end{align}"
                        "\\begin{align} x\n% engine=ratex\n\\end{align}"
                        "$$x = 10\\% engine=ratex$$"
                        "\\[% just a comment\nx\\]"
                        "$x % engine=ratex$"))
        (should (eq (latex-to-svg-frontend--engine-for source) 'latex))))))

(ert-deftest l2sf-cookie-removed-from-value ()
  ;; The backend receives the source without the cookie, and the cookie's
  ;; engine as `:engine'.  The tooltip still shows the source as written.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[% engine=ratex\nx\\]\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (equal l2sf-tests--calls '(("\\[\nx\\]" . ratex))))
      (should (equal (substitute-command-keys
                      (overlay-get (car (l2sf-tests--overlays)) 'help-echo))
                     "Typeset with RaTeX: \\[% engine=ratex\nx\\]")))))

(ert-deftest l2sf-cookie-shares-cache-entry ()
  ;; A cookie that selects the engine the equation would get anyway leaves
  ;; the string sent to the backend unchanged, so it shares the cache entry
  ;; of the same equation written without one.  On its own line, the cookie
  ;; goes with its newline; on the opener line, the newline stays.
  (should (equal (latex-to-svg-frontend--backend-value
                  nil "\\[\n% engine=ratex\nE=mc^2\n\\]" 'ratex)
                 "\\[\nE=mc^2\n\\]"))
  (should (equal (latex-to-svg-frontend--backend-value
                  nil "\\begin{align*}% latex-to-svg: engine=ratex\na &= b\n\\end{align*}" 'ratex)
                 "\\begin{align*}\na &= b\n\\end{align*}"))
  ;; A comment further down is not a cookie and stays.
  (should (equal (latex-to-svg-frontend--backend-value
                  nil "\\begin{align*}\na \\\\% engine=latex\n\\end{align*}" 'ratex)
                 "\\begin{align*}\na \\\\% engine=latex\n\\end{align*}")))

(ert-deftest l2sf-cookie-skip-leaves-source ()
  ;; `skip' and `none' send nothing to the backend; the source stays as text.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[% engine=skip\nx\\]\n\n\\[% engine=none\ny\\]\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should-not l2sf-tests--calls)
      (dolist (ov (l2sf-tests--overlays))
        (should (overlay-get ov 'latex-to-svg-frontend-unrendered))
        (should-not (overlay-get ov 'display))))))

(ert-deftest l2sf-cookie-unknown-value-warns ()
  ;; An unknown value warns, sends nothing to the backend, and does not fall
  ;; back to the default engine.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[% engine=katex\nx\\]\n"
      (let ((warnings nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (latex-to-svg-frontend--render-region (point-min) (point-max)))
        (should-not l2sf-tests--calls)
        (should (= (length warnings) 1))
        (should (string-match-p "katex" (car warnings)))))))

(ert-deftest l2sf-cookie-missing-engine-warns ()
  ;; A cookie naming an engine whose programs are missing warns instead of
  ;; letting the backend draw its placeholder.
  (l2sf-tests--with-stub
    (setq l2sf-tests--missing-engines '(ratex))
    (l2sf-tests--md "\\[% engine=ratex\nx\\]\n"
      (let ((warnings nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (latex-to-svg-frontend--render-region (point-min) (point-max)))
        (should-not l2sf-tests--calls)
        (should (string-match-p "not found" (car warnings)))))))

(ert-deftest l2sf-cookie-skipped-equation-keeps-its-numbers ()
  ;; A skipped `align' is still numbered in the exported document: the
  ;; equation after it keeps its number, and a label inside it resolves.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{align}% engine=skip\na \\label{a} \\\\\nb\n\\end{align}\n\n"
                "\\begin{equation}\nc\n\\end{equation}\n\n"
                "See $\\eqref{a}$.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ovs (l2sf-tests--overlays)))
        (should (equal (overlay-get (nth 0 ovs) 'latex-to-svg-frontend-enums)
                       '(1 . 2)))
        (should (string-prefix-p "\\setcounter{equation}{2}%"
                                 (overlay-get (nth 1 ovs)
                                              'latex-to-svg-frontend-value)))
        (should (equal (overlay-get (nth 2 ovs) 'latex-to-svg-frontend-ref-display)
                       "(1)"))
        ;; The incremental path counts it too.
        (should (= (latex-to-svg-frontend--counter-before
                    (overlay-start (nth 1 ovs)))
                   2))
        (should (equal (gethash "a" (latex-to-svg-frontend--overlay-labels)) 1))))))

(ert-deftest l2sf-cookie-skipped-equation-renumbered ()
  ;; When an equation above a skipped one is removed, the skipped one takes
  ;; its new number range, so the counter after it stays right.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}% engine=skip\nb\n\\end{equation}\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (goto-char (point-min))
      (search-forward "\\begin{equation}") (backward-char 1) (insert "*")
      (search-forward "\\end{equation}") (backward-char 1) (insert "*")
      (latex-to-svg-frontend--reconcile)
      (should (equal (overlay-get (car (last (l2sf-tests--overlays)))
                                  'latex-to-svg-frontend-enums)
                     '(1 . 1))))))

(ert-deftest l2sf-cookie-overrides-option-for-numbering ()
  ;; The `\setcounter'-or-`\tag' choice follows the equation's engine: a
  ;; `latex' cookie under a global `ratex' gets `\setcounter', and the reverse
  ;; gets `\tag'.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}% engine=latex\nx\n\\end{equation}\n"
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
      (should (string-prefix-p "\\setcounter{equation}{0}%"
                               (car (l2sf-tests--values))))
      (should (eq (plist-get l2sf-tests--last-args :engine) 'latex))))
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}% engine=ratex\nx\n\\end{equation}\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (equal (l2sf-tests--values)
                     '("\\begin{equation}\nx\n\\tag{1}\\end{equation}")))
      (should (eq (plist-get l2sf-tests--last-args :engine) 'ratex)))))

(ert-deftest l2sf-cookie-removed-then-rendered ()
  ;; Editing the cookie of a skipped equation away and leaving it renders it.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[% engine=skip\nx\\]\n\nafter\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should-not l2sf-tests--calls)
      (goto-char (point-min))
      (search-forward "skip")
      (replace-match "latex")
      (goto-char (point-max))
      (latex-to-svg-frontend--heal-modified)
      (should (equal l2sf-tests--calls '(("\\[\nx\\]" . latex))))
      (should (eq (overlay-get (car (l2sf-tests--overlays)) 'display)
                  'fake-image)))))

(ert-deftest l2sf-debounced-pass-renders-pasted-math ()
  ;; Math that arrives with no preview (a paste, a yank, an undo) is rendered
  ;; by the debounced pass over the changed range, except the equation that
  ;; contains point, which may still be half typed.
  (l2sf-tests--with-stub
    (l2sf-tests--md "text\n\n"
      (setq-local latex-to-svg-frontend-mode t)
      (goto-char (point-max))
      (let ((beg (point)))
        (insert "$a$\n\n$b$\n")
        (latex-to-svg-frontend--mark-dirty beg (point)))
      (goto-char (point-min))
      (search-forward "$b")
      (latex-to-svg-frontend--debounced-pass (current-buffer))
      (should (equal (l2sf-tests--values) '("$a$")))
      (should-not latex-to-svg-frontend--dirty)
      ;; Once point is elsewhere, the next pass over the range renders $b$.
      (goto-char (point-min))
      (latex-to-svg-frontend--mark-dirty (point-min) (point-max))
      (latex-to-svg-frontend--debounced-pass (current-buffer))
      (should (equal (l2sf-tests--values) '("$a$" "$b$"))))))

(ert-deftest l2sf-debounced-pass-keeps-drawn-previews ()
  ;; A preview already on screen is not rendered again by the pass.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (setq l2sf-tests--calls nil)
      (goto-char (point-max))
      (latex-to-svg-frontend--mark-dirty (point-min) (point-max))
      (latex-to-svg-frontend--debounced-pass (current-buffer))
      (should-not l2sf-tests--calls))))

;;;; Fallback engine and quiet failures

(ert-deftest l2sf-fallback-passed-for-ratex ()
  ;; With the fallback on (the default), a RaTeX equation is sent with
  ;; `:fallback latex'; a LaTeX one gets none, since LaTeX has nothing to
  ;; fall back to.  With the option off, neither gets one.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[x\\]\n"
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (eq (plist-get l2sf-tests--last-args :fallback) 'latex))
        (should (eq (overlay-get (car (l2sf-tests--overlays))
                                 'latex-to-svg-frontend-fallback)
                    'latex)))
      (let ((latex-to-svg-frontend-engine 'latex))
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should-not (plist-get l2sf-tests--last-args :fallback)))
      (let ((latex-to-svg-frontend-engine 'ratex)
            (latex-to-svg-frontend-fallback nil))
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should-not (plist-get l2sf-tests--last-args :fallback))))))

(ert-deftest l2sf-quiet-passed ()
  ;; `:quiet' follows the option: nil by default, t when set, including in
  ;; a refresh.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$x$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (memq :quiet l2sf-tests--last-args))
      (should-not (plist-get l2sf-tests--last-args :quiet))
      (setq-local latex-to-svg-frontend-quiet t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (eq (plist-get l2sf-tests--last-args :quiet) t))
      (setq l2sf-tests--last-args nil)
      (latex-to-svg-frontend-refresh)
      (should (eq (plist-get l2sf-tests--last-args :quiet) t)))))

(ert-deftest l2sf-redraw-uses-recorded-fallback ()
  ;; A redraw (theme, zoom) fetches the picture the overlay was rendered
  ;; with: the same engine and fallback, even after the option changed.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[x\\]\n"
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max)))
      (setq l2sf-tests--last-args nil)
      (let ((latex-to-svg-frontend-fallback nil))
        (latex-to-svg-frontend--refresh-buffer (current-buffer)))
      (should (eq (plist-get l2sf-tests--last-args :engine) 'ratex))
      (should (eq (plist-get l2sf-tests--last-args :fallback) 'latex)))))

(ert-deftest l2sf-help-echo-names-engine ()
  ;; The tooltip names the engine that typeset the picture; a fallback
  ;; picture says which engine could not.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[x\\]\n"
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (equal (substitute-command-keys
                        (overlay-get (car (l2sf-tests--overlays)) 'help-echo))
                       "Typeset with RaTeX: \\[x\\]"))
        (setq l2sf-tests--engine-used 'latex)
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (equal (substitute-command-keys
                        (overlay-get (car (l2sf-tests--overlays)) 'help-echo))
                       "Typeset with LaTeX (RaTeX could not parse it): \\[x\\]"))))))

(ert-deftest l2sf-regenerate-invalidates-fallback ()
  ;; Regenerate deletes the engine's entry (and with it the failure
  ;; record) and the fallback's, so both are compiled again.
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\[x\\]\n"
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend-refresh nil '(4)))
      (should (equal l2sf-tests--invalidated-engines '(latex ratex)))
      (setq l2sf-tests--invalidated-engines nil)
      (let ((latex-to-svg-frontend-engine 'ratex)
            (latex-to-svg-frontend-fallback nil))
        (latex-to-svg-frontend-refresh nil '(4)))
      (should (equal l2sf-tests--invalidated-engines '(ratex))))))

(ert-deftest l2sf-regenerate-invalidates-format-for-latex ()
  ;; Regenerate deletes the buffer's `.fmt' file once, so an edit to a file
  ;; its preamble loads reaches the recompiled equations; only when an
  ;; equation is typeset with LaTeX, as the engine or the fallback.
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n\n\\[x\\]\n"
      (latex-to-svg-frontend-refresh nil '(4))
      (should (= l2sf-tests--formats-invalidated 1))
      (let ((latex-to-svg-frontend-engine 'ratex))
        (latex-to-svg-frontend-refresh nil '(4)))
      (should (= l2sf-tests--formats-invalidated 2))
      (let ((latex-to-svg-frontend-engine 'ratex)
            (latex-to-svg-frontend-fallback nil))
        (latex-to-svg-frontend-refresh nil '(4)))
      (should (= l2sf-tests--formats-invalidated 2)))))

;;;; Inline / display rescale

(ert-deftest l2sf-classifies-display-vs-inline ()
  (should-not (latex-to-svg-frontend--display-p "$x$"))
  (should-not (latex-to-svg-frontend--display-p "\\(x\\)"))
  (should (latex-to-svg-frontend--display-p "\\[x\\]"))
  (should (latex-to-svg-frontend--display-p "$$x$$"))
  (should (latex-to-svg-frontend--display-p "\\begin{equation}x\\end{equation}")))

(ert-deftest l2sf-passes-inline-and-display-rescale ()
  (l2sf-tests--with-stub
    (let ((latex-to-svg-frontend-inline-rescale 1.0)
          (latex-to-svg-frontend-display-rescale 1.4)
          (latex-to-svg-frontend-number-equations nil))
      (l2sf-tests--md "inline $a$ end\n"
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (equal l2sf-tests--last-rescale 1.0)))
      (l2sf-tests--md "\\[b\\]\n"
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (equal l2sf-tests--last-rescale 1.4))))))

(ert-deftest l2sf-padding-obsolete-alias-tracks-the-new-name ()
  ;; The pre-0.16.0 name stays usable: it is an alias for the new one, so a
  ;; config that still sets it keeps working.  (That a value set *before* this
  ;; file loads survives depends on the alias preceding the defcustom in the
  ;; source -- `defvaralias' discards a value the obsolete name already holds.)
  (should (eq (indirect-variable 'latex-to-svg-frontend-background-padding)
              'latex-to-svg-frontend-padding))
  (should (get 'latex-to-svg-frontend-background-padding 'byte-obsolete-variable))
  (let ((latex-to-svg-frontend-background-padding '(0 0 0 6)))
    (should (equal latex-to-svg-frontend-padding '(0 0 0 6)))))

(defun l2sf-tests--center-spec (ov)
  "Return the `display' spec of OV's centering prefix, or nil."
  (when-let* ((pre (overlay-get ov 'before-string)))
    (get-text-property 0 'display pre)))

(ert-deftest l2sf-centers-display-math-only ()
  ;; Centering is a display-time indent on display math: a one-space
  ;; `before-string' whose stretch reaches the window center less half the
  ;; image.  Inline math belongs in the run of text and is never centered.
  (l2sf-tests--with-stub
    (let ((latex-to-svg-frontend-center-display-math t)
          (latex-to-svg-frontend-number-equations nil))
      (l2sf-tests--md "\\[a\\]\n\ntext \\(b\\) more\n"
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (let ((ovs (l2sf-tests--overlays)))
          (should (= (length ovs) 2))
          (dolist (ov ovs)
            (if (overlay-get ov 'latex-to-svg-frontend-display-math)
                (progn
                  (should (equal (overlay-get ov 'before-string) " "))
                  ;; The image itself appears in the spec -- that is what
                  ;; lets redisplay size the stretch without measuring it.
                  (should (equal (l2sf-tests--center-spec ov)
                                 `(space :align-to
                                         (- center (0.5 . ,l2sf-tests--image))))))
              (should-not (overlay-get ov 'before-string)))))))))

(ert-deftest l2sf-centering-off-by-default ()
  ;; Off, nothing is indented -- previews start at the left margin as before.
  (l2sf-tests--with-stub
    (should-not latex-to-svg-frontend-center-display-math)
    (let ((latex-to-svg-frontend-number-equations nil))
      (l2sf-tests--md "\\[a\\]\n"
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (dolist (ov (l2sf-tests--overlays))
          (should-not (overlay-get ov 'before-string)))))))

(ert-deftest l2sf-centering-follows-reveal-and-refresh ()
  ;; The prefix embeds the image, so it must track every show/hide: revealed
  ;; source must not sit behind a leftover stretch, and a refresh (which
  ;; rebuilds the image) must rebuild the prefix with it.
  (l2sf-tests--with-stub
    (let ((latex-to-svg-frontend-center-display-math t)
          (latex-to-svg-frontend-number-equations nil))
      (l2sf-tests--md "\\[a\\]\n"
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (let ((ov (car (l2sf-tests--overlays))))
          (should (overlay-get ov 'before-string))
          ;; Revealed for editing: image and prefix both gone.
          (latex-to-svg-frontend--open-overlay ov)
          (should-not (overlay-get ov 'display))
          (should-not (overlay-get ov 'before-string))
          ;; Cursor leaves: both back.
          (latex-to-svg-frontend--close-overlay ov)
          (should (overlay-get ov 'display))
          (should (overlay-get ov 'before-string))
          ;; A refresh re-threads the prefix against the rebuilt image.
          (let ((l2sf-tests--image 'rebuilt-image))
            (latex-to-svg-frontend-refresh)
            (should (equal (l2sf-tests--center-spec ov)
                           '(space :align-to (- center (0.5 . rebuilt-image)))))))))))

(ert-deftest l2sf-every-option-is-safe-except-the-mode-hook ()
  ;; This package's options are all inert data -- booleans, numbers, colors,
  ;; environment names -- so a project can set them in `.dir-locals.el'
  ;; without a prompt.  The mode hook is the exception, and stays one: a
  ;; file-local hook is arbitrary code.  (What is executed and what LaTeX is
  ;; compiled belongs to the backend, which keeps those options unsafe.)
  (let (unsafe)
    (mapatoms
     (lambda (sym)
       (when (and (get sym 'custom-type)
                  (string-prefix-p "latex-to-svg-frontend-" (symbol-name sym))
                  (not (get sym 'safe-local-variable)))
         (push sym unsafe))))
    (should (equal unsafe '(latex-to-svg-frontend-mode-hook)))))

(ert-deftest l2sf-padding-safe-matches-the-backend ()
  ;; A file-local padding is hand-written Lisp, so the `:safe' predicate
  ;; accepts every shape the backend takes (1-4 numbers) and nothing else --
  ;; a value Customize cannot express must still not need a y/n prompt.
  (let ((safe (get 'latex-to-svg-frontend-padding 'safe-local-variable)))
    (should safe)
    (dolist (ok (list nil 3 3.5 '(0 0 0 6) '(2 6) '(1 2 3)))
      (should (funcall safe ok)))
    (dolist (bad (list "3" '(1 2 3 4 5) '(1 "2") 'x))
      (should-not (funcall safe bad))))
  ;; The colors it is threaded with are safe as data too.
  (dolist (v '(latex-to-svg-frontend-foreground-color
               latex-to-svg-frontend-background-color))
    (should (get v 'safe-local-variable))))

(ert-deftest l2sf-passes-color-background-padding ()
  ;; The three appearance defcustoms are threaded to the backend as
  ;; :color / :background / :padding (both on first render and on refresh).
  (l2sf-tests--with-stub
    (let ((latex-to-svg-frontend-foreground-color "red")
          (latex-to-svg-frontend-background-color "gray97")
          (latex-to-svg-frontend-padding 6)
          (latex-to-svg-frontend-number-equations nil))
      (l2sf-tests--md "\\[b\\]\n"
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (equal (plist-get l2sf-tests--last-args :color) "red"))
        (should (equal (plist-get l2sf-tests--last-args :background) "gray97"))
        (should (equal (plist-get l2sf-tests--last-args :padding) 6))
        ;; Refresh re-threads them too.
        (setq l2sf-tests--last-args nil)
        (latex-to-svg-frontend-refresh)
        (should (equal (plist-get l2sf-tests--last-args :color) "red"))
        (should (equal (plist-get l2sf-tests--last-args :background) "gray97"))
        (should (equal (plist-get l2sf-tests--last-args :padding) 6))))))

(ert-deftest l2sf-refresh-rescales-by-kind ()
  (l2sf-tests--with-stub
    (let ((latex-to-svg-frontend-inline-rescale 1.0)
          (latex-to-svg-frontend-display-rescale 1.4)
          (latex-to-svg-frontend-number-equations nil))
      (l2sf-tests--md "\\[b\\]\n"
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (let ((ov (car (l2sf-tests--overlays))))
          (should (overlay-get ov 'latex-to-svg-frontend-display-math))
          (setq l2sf-tests--last-rescale nil)
          (latex-to-svg-frontend-refresh)
          (should (equal l2sf-tests--last-rescale 1.4)))))))

;;;; \eqref / \ref

(ert-deftest l2sf-scan-harvests-labels ()
  (l2sf-tests--md
      (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
              "\\begin{align}\ny&=1\\label{eq:b}\\\\\nz&=2\\label{eq:c}\n\\end{align}\n")
    (let ((labels (cdr (latex-to-svg-frontend--scan-numbering))))
      (should (= 1 (gethash "eq:a" labels)))
      (should (= 2 (gethash "eq:b" labels)))
      (should (= 3 (gethash "eq:c" labels))))))

(ert-deftest l2sf-nonumber-row-label-skipped ()
  (l2sf-tests--md
      (concat "\\begin{align}\n"
              "a&=1\\label{eq:x}\\\\\n"
              "b&=2\\nonumber\\label{eq:y}\\\\\n"
              "c&=3\\label{eq:z}\n"
              "\\end{align}\n")
    (let ((labels (cdr (latex-to-svg-frontend--scan-numbering))))
      (should (= 1 (gethash "eq:x" labels)))
      (should (null (gethash "eq:y" labels)))
      (should (= 2 (gethash "eq:z" labels))))))

(ert-deftest l2sf-reference-display-renders ()
  (let ((labels (make-hash-table :test 'equal)))
    (puthash "eq:a" 7 labels)
    (should (equal "(7)" (latex-to-svg-frontend--reference-display "\\eqref{eq:a}" labels)))
    (should (equal "7"   (latex-to-svg-frontend--reference-display "\\ref{eq:a}" labels)))
    (should (equal "(7)" (latex-to-svg-frontend--reference-display "$\\eqref{eq:a}$" labels)))
    (should (equal "(7)" (latex-to-svg-frontend--reference-display "\\(\\eqref{eq:a}\\)" labels)))
    (should (null (latex-to-svg-frontend--reference-display "\\eqref{eq:missing}" labels)))
    (should (null (latex-to-svg-frontend--reference-display "$x=1$" labels)))))

(ert-deftest l2sf-renders-eqref-as-text ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "As in \\eqref{eq:a}.\n")
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let* ((ovs (l2sf-tests--overlays))
             (ref (car (last ovs))))
        (should (equal (substring-no-properties (overlay-get ref 'display)) "(1)"))
        (should (null (overlay-get ref 'latex-to-svg-frontend-value)))
        (should (equal (overlay-get ref 'latex-to-svg-frontend-ref) "eq:a"))
        (should (eq (overlay-get ref 'keymap)
                    latex-to-svg-frontend--reference-keymap))))))

(ert-deftest l2sf-label-position-finds-defining-element ()
  (l2sf-tests--md
      (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
              "\\begin{align}\ny&=1\\label{eq:b}\\\\\nz&=2\n\\end{align}\n")
    (should (= (latex-to-svg-frontend--label-position "eq:a") (point-min)))
    (let ((align-begin (save-excursion (goto-char (point-min))
                                       (search-forward "\\begin{align}")
                                       (match-beginning 0))))
      (should (= (latex-to-svg-frontend--label-position "eq:b") align-begin)))
    (should (null (latex-to-svg-frontend--label-position "eq:missing")))))

(ert-deftest l2sf-goto-reference-jumps-to-target ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "See \\eqref{eq:a}.\n\n"
                "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n")
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let* ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                            (l2sf-tests--overlays)))
             (target (save-excursion (goto-char (point-min))
                                     (search-forward "\\begin{equation}")
                                     (match-beginning 0))))
        (goto-char (overlay-start ref))
        (latex-to-svg-frontend-goto-reference)
        (should (= (point) target))))))

(ert-deftest l2sf-goto-reference-asks-find-label-function ()
  ;; A label no equation in the buffer defines goes to
  ;; `latex-to-svg-frontend-find-label-function', with point on the
  ;; reference.  It answering nil, or no function, is an error; a label an
  ;; equation defines never reaches it.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "See \\ref{sec:b} and \\eqref{eq:a}.\n\n"
                "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n")
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let* ((refs (seq-filter (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                               (l2sf-tests--overlays)))
             (asked nil)
             (answer t))
        (setq-local latex-to-svg-frontend-find-label-function
                    (lambda (label) (push (cons label (point)) asked) answer))
        (goto-char (overlay-start (car refs)))
        (latex-to-svg-frontend-goto-reference)
        (should (equal asked (list (cons "sec:b" (overlay-start (car refs))))))
        (setq answer nil)
        (goto-char (overlay-start (car refs)))
        (should-error (latex-to-svg-frontend-goto-reference) :type 'user-error)
        (setq asked nil)
        (goto-char (overlay-start (cadr refs)))
        (latex-to-svg-frontend-goto-reference)
        (should-not asked)
        (kill-local-variable 'latex-to-svg-frontend-find-label-function)
        (goto-char (overlay-start (car refs)))
        (should-error (latex-to-svg-frontend-goto-reference) :type 'user-error)))))

(ert-deftest l2sf-eqref-follows-renumber ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\\label{eq:b}\nb\n\\end{equation}\n\n"
                "See \\eqref{eq:b}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (equal "(2)"
                     (substring-no-properties
                      (overlay-get (car (last (l2sf-tests--overlays))) 'display))))
      (goto-char (point-min))
      (search-forward "\\begin{equation}") (backward-char 1) (insert "*")
      (search-forward "\\end{equation}") (backward-char 1) (insert "*")
      (latex-to-svg-frontend--reconcile)
      (should (equal "(1)"
                     (substring-no-properties
                      (overlay-get (car (last (l2sf-tests--overlays))) 'display)))))))

(ert-deftest l2sf-reference-dangles-when-target-deleted ()
  ;; Deleting the equation that defines a label makes every reference to it
  ;; visibly broken: `(1)' -> `(??)' after a reconcile.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "See \\eqref{eq:a}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (equal "(1)"
                     (substring-no-properties
                      (overlay-get (car (last (l2sf-tests--overlays))) 'display))))
      ;; Delete the whole equation that defines eq:a.
      (goto-char (point-min))
      (search-forward "\\begin{equation}")
      (let ((b (match-beginning 0)))
        (search-forward "\\end{equation}")
        (delete-region b (point)))
      (latex-to-svg-frontend--reconcile)
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (should ref)
        (should (equal "(??)" (substring-no-properties (overlay-get ref 'display))))
        (should (null (overlay-get ref 'latex-to-svg-frontend-ref-num)))))))

(ert-deftest l2sf-reference-resolves-when-target-added ()
  ;; A reference to a not-yet-defined label renders as `(??)', then resolves to
  ;; a number once the labelled equation is added and reconciled.
  (l2sf-tests--with-stub
    (l2sf-tests--md "See \\eqref{eq:a}.\n"
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (should ref)
        (should (equal "(??)" (substring-no-properties (overlay-get ref 'display)))))
      ;; Add the labelled equation above, then reconcile.
      (goto-char (point-min))
      (insert "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n")
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (latex-to-svg-frontend--reconcile)
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (should (equal "(1)" (substring-no-properties (overlay-get ref 'display))))
        (should (= 1 (overlay-get ref 'latex-to-svg-frontend-ref-num)))))))

(ert-deftest l2sf-reference-follows-label-edit ()
  ;; Renaming an equation's \label re-points references: one to the OLD label
  ;; goes `(??)', one to the NEW label resolves.  This falls out of the full
  ;; re-resolve in `--reconcile-references' (no per-overlay label state).
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "See \\eqref{eq:a} and \\eqref{eq:c}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (latex-to-svg-frontend--reconcile)
      (cl-flet ((ref (label)
                  (seq-find (lambda (o)
                              (equal (overlay-get o 'latex-to-svg-frontend-ref) label))
                            (latex-to-svg-frontend--overlays-in (point-min) (point-max))))
                (disp (o) (substring-no-properties (overlay-get o 'display))))
        (should (equal "(1)"  (disp (ref "eq:a"))))
        (should (equal "(??)" (disp (ref "eq:c"))))
        ;; Rename the equation's label eq:a -> eq:c.
        (goto-char (point-min))
        (search-forward "\\label{eq:a}")
        (replace-match "\\label{eq:c}" nil t)
        (latex-to-svg-frontend--reconcile)
        (should (equal "(??)" (disp (ref "eq:a"))))    ; old target gone
        (should (equal "(1)"  (disp (ref "eq:c"))))))))  ; new target resolves

(defun l2sf-tests--ref-displays ()
  "Return the display text of each reference overlay, in buffer order."
  (delq nil (mapcar (lambda (o)
                      (and (overlay-get o 'latex-to-svg-frontend-ref)
                           (substring-no-properties (overlay-get o 'display))))
                    (l2sf-tests--overlays))))

(ert-deftest l2sf-labels-function-resolves-references ()
  ;; With `latex-to-svg-frontend-labels-function' set, references resolve
  ;; against its table, whose numbers are strings: `\ref' -> "2.1",
  ;; `\eqref' -> "(2.1)", a missing label -> "??".  It replaces the
  ;; buffer's own equation labels: eq:a, defined in the buffer but not in
  ;; the table, dangles.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "See \\ref{sec:b}, \\eqref{sec:b}, \\ref{sec:none}, \\eqref{eq:a}.\n")
      (let ((table (make-hash-table :test 'equal)))
        (puthash "sec:b" "2.1" table)
        (setq-local latex-to-svg-frontend-labels-function (lambda () table))
        (latex-to-svg-frontend--render-region (point-min) (point-max))
        (should (equal (l2sf-tests--ref-displays)
                       '("2.1" "(2.1)" "??" "(??)")))))))

(ert-deftest l2sf-labels-function-follows-its-table ()
  ;; A reconcile re-resolves the references against the table the function
  ;; returns now, also with numbering off, which without the function
  ;; draws no reference at all.
  (dolist (numbering '(t nil))
    (l2sf-tests--with-stub
      (l2sf-tests--md "See \\ref{sec:b}.\n"
        (let ((table (make-hash-table :test 'equal)))
          (puthash "sec:b" "2.1" table)
          (setq-local latex-to-svg-frontend-mode t)
          (setq-local latex-to-svg-frontend-number-equations numbering)
          (setq-local latex-to-svg-frontend-labels-function (lambda () table))
          (latex-to-svg-frontend--render-region (point-min) (point-max))
          (should (equal (l2sf-tests--ref-displays) '("2.1")))
          (puthash "sec:b" "3.4" table)
          (latex-to-svg-frontend--reconcile)
          (should (equal (l2sf-tests--ref-displays) '("3.4")))
          (remhash "sec:b" table)
          (latex-to-svg-frontend--reconcile-from (point-min))
          (should (equal (l2sf-tests--ref-displays) '("??"))))))))

(ert-deftest l2sf-reference-reveals-under-cursor ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "As in \\eqref{eq:a}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (goto-char (1+ (overlay-start ref)))
        (latex-to-svg-frontend--handle-cursor)
        (should (null (overlay-get ref 'display)))
        (goto-char (point-min))
        (latex-to-svg-frontend--handle-cursor)
        (should (equal "(1)" (substring-no-properties (overlay-get ref 'display))))))))

(ert-deftest l2sf-reference-keymap-follows-link ()
  ;; References are clickable the Emacs way: mouse-2 jumps, and the span is
  ;; declared a link via `follow-link' so a short mouse-1 click is translated
  ;; to mouse-2 (a long one falls through and reveals the source instead).
  (should (eq #'latex-to-svg-frontend-goto-reference
              (lookup-key latex-to-svg-frontend--reference-keymap [mouse-2])))
  (should (null (lookup-key latex-to-svg-frontend--reference-keymap [mouse-1])))
  (should (eq 'mouse-face
              (lookup-key latex-to-svg-frontend--reference-keymap
                          [follow-link])))
  (should (eq #'latex-to-svg-frontend-goto-reference
              (lookup-key latex-to-svg-frontend--reference-keymap
                          (kbd "C-c C-o")))))

(ert-deftest l2sf-reference-ret-is-opt-in ()
  ;; RET must stay `newline' by default (the buffer is editable, and the
  ;; keymap is already active with point at the reference's first character),
  ;; mirroring `org-return-follows-link'.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "  \\eqref{eq:a}  \n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let* ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                            (l2sf-tests--overlays)))
             (beg (overlay-start ref)))
        (let ((latex-to-svg-frontend-return-follows-reference nil))
          (should-not (eq #'latex-to-svg-frontend-goto-reference
                          (key-binding (kbd "RET") nil nil beg))))
        (let ((latex-to-svg-frontend-return-follows-reference t))
          (should (eq #'latex-to-svg-frontend-goto-reference
                      (key-binding (kbd "RET") nil nil beg))))
        ;; C-c C-o follows either way, and neither binding leaks outside.
        (should (eq #'latex-to-svg-frontend-goto-reference
                    (key-binding (kbd "C-c C-o") nil nil beg)))
        (should-not (eq #'latex-to-svg-frontend-goto-reference
                        (key-binding (kbd "C-c C-o") nil nil (1- beg))))))))

(ert-deftest l2sf-reference-overlay-is-a-link ()
  ;; `follow-link' => `mouse-face' only works if the overlay carries a
  ;; `mouse-face' property, and the help-echo must start with "mouse-2" for
  ;; `mouse-fixup-help-message' to adapt it to the user's setting.
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "As in \\eqref{eq:a}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (should (overlay-get ref 'mouse-face))
        (should (eq latex-to-svg-frontend--reference-keymap
                    (overlay-get ref 'keymap)))
        (should (string-prefix-p "mouse-2" (overlay-get ref 'help-echo)))))))

(ert-deftest l2sf-reference-mouse-entry-does-not-reveal ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "As in \\eqref{eq:a}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        ;; Mouse entry keeps the number shown.  Revealing on the button press
        ;; would reflow the line and make Emacs report the release as
        ;; `drag-mouse-1' (keyboard.c requires the buffer position under the
        ;; pointer to be unchanged), which would defeat `follow-link'.
        (goto-char (1+ (overlay-start ref)))
        (let ((last-command-event 'mouse-1))
          (latex-to-svg-frontend--handle-cursor))
        (should (equal "(1)" (substring-no-properties (overlay-get ref 'display))))
        ;; Keyboard entry still reveals.
        (goto-char (point-min))
        (let ((last-command-event 'right)) (latex-to-svg-frontend--handle-cursor))
        (goto-char (1+ (overlay-start ref)))
        (let ((last-command-event 'right)) (latex-to-svg-frontend--handle-cursor))
        (should (null (overlay-get ref 'display)))))))

(ert-deftest l2sf-plain-ref-reveals-under-cursor ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "See \\ref{eq:a}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (should (equal "1" (substring-no-properties (overlay-get ref 'display))))
        (goto-char (1+ (overlay-start ref)))
        (latex-to-svg-frontend--handle-cursor)
        (should (null (overlay-get ref 'display)))
        (goto-char (point-min))
        (latex-to-svg-frontend--handle-cursor)
        (should (equal "1" (substring-no-properties (overlay-get ref 'display))))))))

(ert-deftest l2sf-reference-rerenders-after-label-edit ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "\\begin{equation}\\label{eq:b}\ny\n\\end{equation}\n\n"
                "As in \\eqref{eq:a}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (goto-char (1+ (overlay-start ref)))
        (latex-to-svg-frontend--handle-cursor)
        (save-excursion
          (goto-char (overlay-start ref))
          (search-forward "eq:a")
          (replace-match "eq:b"))
        (goto-char (point-min))
        (latex-to-svg-frontend--handle-cursor))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (should (equal (overlay-get ref 'latex-to-svg-frontend-ref) "eq:b"))
        (should (equal "(2)" (substring-no-properties (overlay-get ref 'display))))))))

;;; --- Release hygiene ------------------------------------------------------

(defconst l2sf-tests--repo-root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Directory holding the three packages and `CHANGELOG.md'.")

(defun l2sf-tests--header-version (file)
  "Return the `Version:' header of FILE, relative to the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file l2sf-tests--repo-root))
    (lm-header "version")))

(defun l2sf-tests--changelog-latest ()
  "Return the newest dated version in `CHANGELOG.md', as a string."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "CHANGELOG.md" l2sf-tests--repo-root))
    (goto-char (point-min))
    (and (re-search-forward "^## \\[\\([0-9.]+\\)\\] - " nil t)
         (match-string 1))))

(ert-deftest l2sf-package-versions-agree ()
  ;; Drift guard: the repository ships four packages on one version stream,
  ;; so their `Version:' headers are bumped together.
  (let ((versions (mapcar #'l2sf-tests--header-version
                          '("latex-to-svg-frontend.el"
                            "latex-to-svg-for-org.el"
                            "latex-to-svg-for-markdown.el"
                            "latex-to-svg-for-latex.el"))))
    (should (seq-every-p #'stringp versions))
    (should (equal (seq-uniq versions) (list (car versions))))))

(ert-deftest l2sf-changelog-not-behind-package-version ()
  ;; Drift guard: a released section never claims a version the sources have
  ;; not reached.  Between releases the headers may run ahead of the newest
  ;; dated section, with the entries under `[Unreleased]'.
  (let ((header (l2sf-tests--header-version "latex-to-svg-frontend.el"))
        (changelog (l2sf-tests--changelog-latest)))
    (should (stringp changelog))
    (should (version<= changelog header))))

(provide 'latex-to-svg-frontend-tests)

;;; latex-to-svg-frontend-tests.el ends here
