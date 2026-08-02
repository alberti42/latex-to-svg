;;; latex-to-svg-frontend-tests.el --- Tests for latex-to-svg-frontend -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/latex-to-svg-frontend-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The engine (`latex-to-svg-backend') is stubbed to return a synchronous fake image,
;; so no TeX toolchain or graphical display is needed.  Math detection is a
;; regexp scanner, so most tests run in a plain temp buffer with no tree-sitter
;; grammar required; only the minor-mode enable/disable test needs a real
;; Markdown major mode.

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))

;; `latex-to-svg-backend' (the engine) is a sibling repo; add it to `load-path' so the
;; module's `(require 'latex-to-svg-backend)' resolves when running from a checkout.
(let ((dir (or (getenv "LATEX_TO_SVG_DIR")
               (expand-file-name "../../latex-to-svg-backend"
                                 (file-name-directory
                                  (or load-file-name buffer-file-name))))))
  (when (file-directory-p dir)
    (add-to-list 'load-path dir)))

(require 'latex-to-svg-backend)
(require 'latex-to-svg-frontend)
(require 'latex-to-svg-for-markdown)
(require 'latex-to-svg-for-org)
;; Built-in on Emacs 31+; only needed for the minor-mode enable/disable test,
;; which skips itself when it (or the `markdown' grammar) is unavailable.
(require 'markdown-ts-mode nil t)

;; --- Stub the engine: synchronous, deterministic, no TeX / no display -------

(defvar l2sf-tests--image 'fake-image)

(defmacro l2sf-tests--with-stub (&rest body)
  "Run BODY with the engine stubbed to return `l2sf-tests--image'."
  (declare (indent 0) (debug t))
  `(let ((l2sf-tests--appearance '("#000" "#fff" 20))
         (l2sf-tests--invalidated nil)
         (l2sf-tests--metadata nil)
         (l2sf-tests--last-rescale nil)
         (latex-to-svg-backend-metadata-prefix nil))
     (cl-letf (((symbol-function 'latex-to-svg-backend)
                (lambda (_latex &rest args)
                  (setq l2sf-tests--last-rescale (plist-get args :rescale-by))
                  l2sf-tests--image))
               ((symbol-function 'latex-to-svg-backend-appearance)
                (lambda () l2sf-tests--appearance))
               ((symbol-function 'latex-to-svg-backend-metadata)
                (lambda (value) (cdr (assoc value l2sf-tests--metadata))))
               ((symbol-function 'latex-to-svg-backend-invalidate)
                (lambda (latex) (push latex l2sf-tests--invalidated))))
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
  ;; all — exactly what the verbatim engine wants).
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

(ert-deftest l2sf-toggle-dollar-off ()
  (l2sf-tests--md "$a$ and \\(b\\)\n"
    (let ((latex-to-svg-frontend-detect-dollar-delimiters nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("\\(b\\)"))))))

(ert-deftest l2sf-toggle-bracket-off ()
  (l2sf-tests--md "$a$ and \\(b\\) and \\[c\\]\n"
    (let ((latex-to-svg-frontend-detect-bracket-delimiters nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$a$"))))))

(ert-deftest l2sf-toggle-environments-off ()
  (l2sf-tests--md "$a$\n\n\\begin{equation}\nx\n\\end{equation}\n"
    (let ((latex-to-svg-frontend-detect-environments nil))
      (should (equal (mapcar #'latex-to-svg-frontend--math-value
                             (latex-to-svg-frontend--elements (point-min) (point-max)))
                     '("$a$"))))))

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

(ert-deftest l2sf-command-toggles-at-point ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ text\n"
      (goto-char (+ (point-min) 1))
      (latex-to-svg-frontend)
      (should (= 1 (length (l2sf-tests--overlays))))
      (goto-char (+ (point-min) 1))
      (latex-to-svg-frontend)
      (should (null (l2sf-tests--overlays))))))

(ert-deftest l2sf-command-rerenders-with-prefix ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ $b$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (= 2 (length (l2sf-tests--overlays))))
      (let ((l2sf-tests--image 'rebuilt))
        (latex-to-svg-frontend '(4)))
      (let ((ovs (l2sf-tests--overlays)))
        (should (= 2 (length ovs)))
        (should (cl-every (lambda (o) (eq (overlay-get o 'display) 'rebuilt)) ovs))))))

(ert-deftest l2sf-command-regenerates-with-double-prefix ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ \\[b\\]\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (latex-to-svg-frontend '(16))
      (should (equal (sort (copy-sequence l2sf-tests--invalidated) #'string<)
                     '("$a$" "\\[b\\]")))
      (should (= 2 (length (l2sf-tests--overlays)))))))

(ert-deftest l2sf-clear-command ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$ $b$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (should (= 2 (length (l2sf-tests--overlays))))
      (latex-to-svg-frontend-clear)
      (should (null (l2sf-tests--overlays))))))

(ert-deftest l2sf-regenerate-command ()
  (l2sf-tests--with-stub
    (l2sf-tests--md "$a$\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((l2sf-tests--image 'fresh))
        (latex-to-svg-frontend-regenerate))
      (should (equal l2sf-tests--invalidated '("$a$")))
      (let ((ovs (l2sf-tests--overlays)))
        (should (= 1 (length ovs)))
        (should (eq (overlay-get (car ovs) 'display) 'fresh))))))

;;;; Minor mode

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
  (l2sf-tests--with-stub
    (l2sf-tests--md "\\begin{equation}\nx\n\\end{equation}\n"
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ov (car (l2sf-tests--overlays))))
        (should (equal (overlay-get ov 'help-echo)
                       "\\begin{equation}\nx\n\\end{equation}"))
        (should-not (string-match-p "setcounter" (overlay-get ov 'help-echo)))))))

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
        (latex-to-svg-frontend-regenerate))
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

(ert-deftest l2sf-reference-mouse-entry-does-not-reveal ()
  (l2sf-tests--with-stub
    (l2sf-tests--md
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "As in \\eqref{eq:a}.\n")
      (setq-local latex-to-svg-frontend-mode t)
      (latex-to-svg-frontend--render-region (point-min) (point-max))
      (let ((ref (seq-find (lambda (o) (overlay-get o 'latex-to-svg-frontend-ref))
                           (l2sf-tests--overlays))))
        (goto-char (1+ (overlay-start ref)))
        (let ((last-command-event 'mouse-1))
          (latex-to-svg-frontend--handle-cursor))
        (should (equal "(1)" (substring-no-properties (overlay-get ref 'display))))
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

(provide 'latex-to-svg-frontend-tests)

;;; latex-to-svg-frontend-tests.el ends here
