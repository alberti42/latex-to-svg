;;; org-latex-to-svg-tests.el --- Tests for org-latex-to-svg -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/org-latex-to-svg-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The engine (`latex-to-svg') is stubbed to return a synchronous fake image,
;; so no TeX toolchain or graphical display is needed; the tests exercise
;; detection, overlay placement / clearing, the command, and the refresh path.

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))

;; `latex-to-svg' (the engine) is a sibling repo; add it to `load-path' so the
;; module's `(require 'latex-to-svg)' resolves when running from a checkout.
(let ((dir (or (getenv "LATEX_TO_SVG_DIR")
               (expand-file-name "../../latex-to-svg"
                                 (file-name-directory
                                  (or load-file-name buffer-file-name))))))
  (when (file-directory-p dir)
    (add-to-list 'load-path dir)))

(require 'latex-to-svg)
(require 'org-latex-to-svg)

;; --- Stub the engine: synchronous, deterministic, no TeX / no display -------
;;
;; `org-latex-to-svg-tests--image' is what the stubbed `latex-to-svg' returns;
;; rebinding it and refreshing lets a test simulate a theme/zoom change.

(defvar org-latex-to-svg-tests--image 'fake-image)

(defmacro org-latex-to-svg-tests--with-stub (&rest body)
  "Run BODY with the engine stubbed to return `org-latex-to-svg-tests--image'.
`latex-to-svg' returns the fake image synchronously (so overlays land
immediately) and `latex-to-svg-appearance' is a mutable list a test can
change to simulate a theme/font change."
  (declare (indent 0) (debug t))
  `(let ((org-latex-to-svg-tests--appearance '("#000" "#fff" 20))
         (org-latex-to-svg-tests--invalidated nil)
         (org-latex-to-svg-tests--metadata nil)
         (org-latex-to-svg-tests--last-rescale nil)
         (latex-to-svg-metadata-prefix nil))
     (cl-letf (((symbol-function 'latex-to-svg)
                (lambda (_latex &rest args)
                  (setq org-latex-to-svg-tests--last-rescale
                        (plist-get args :rescale-by))
                  org-latex-to-svg-tests--image))
               ((symbol-function 'latex-to-svg-appearance)
                (lambda () org-latex-to-svg-tests--appearance))
               ((symbol-function 'latex-to-svg-flush-metrics) #'ignore)
               ((symbol-function 'latex-to-svg-metadata)
                (lambda (value) (cdr (assoc value org-latex-to-svg-tests--metadata))))
               ((symbol-function 'latex-to-svg-invalidate)
                (lambda (latex) (push latex org-latex-to-svg-tests--invalidated))))
       ,@body)))

(defmacro org-latex-to-svg-tests--org (text &rest body)
  "In a temp Org buffer containing TEXT, run BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (let ((org-mode-hook nil))
       (org-mode))
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun org-latex-to-svg-tests--overlays ()
  "Return this package's overlays in the current buffer, sorted by start."
  (sort (org-latex-to-svg--overlays-in (point-min) (point-max))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

;;;; Detection

(ert-deftest org-latex-to-svg-detects-fragments-and-environments ()
  ;; `--elements' finds inline `$...$' / `\(...\)', display `\[...\]', and
  ;; environments, returning each element's verbatim `:value' (delimiters and
  ;; all — exactly what the verbatim engine wants).
  (org-latex-to-svg-tests--org
      "Inline $E=mc^2$ and \\(a+b\\).\n\nDisplay \\[F=ma\\]\n\n\\begin{equation}\nx=1\n\\end{equation}\n"
    (should (equal (mapcar (lambda (el) (org-element-property :value el))
                           (org-latex-to-svg--elements (point-min) (point-max)))
                   ;; Org's `latex-environment' :value keeps its trailing
                   ;; newline; fragments carry their delimiters verbatim.
                   '("$E=mc^2$"
                     "\\(a+b\\)"
                     "\\[F=ma\\]"
                     "\\begin{equation}\nx=1\n\\end{equation}\n")))))

(ert-deftest org-latex-to-svg-element-bounds-trim-trailing-blank ()
  ;; The overlay span excludes Org's trailing post-blank whitespace, so it
  ;; covers just the fragment text.
  (org-latex-to-svg-tests--org "$x$   after\n"
    (let* ((el (car (org-latex-to-svg--elements (point-min) (point-max))))
           (bounds (org-latex-to-svg--element-bounds el)))
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "$x$")))))

;;;; Rendering / overlays

(ert-deftest org-latex-to-svg-renders-overlay-per-element ()
  ;; Rendering the buffer lays one image overlay over each element, tagged with
  ;; the element's source value.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ and \\[b\\]\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (let ((ovs (org-latex-to-svg-tests--overlays)))
        (should (= (length ovs) 2))
        (should (equal (mapcar (lambda (o) (overlay-get o 'org-latex-to-svg-value)) ovs)
                       '("$a$" "\\[b\\]")))
        (should (cl-every (lambda (o) (eq (overlay-get o 'display) 'fake-image)) ovs))
        ;; The overlay covers exactly the fragment source.
        (should (equal (buffer-substring-no-properties
                        (overlay-start (car ovs)) (overlay-end (car ovs)))
                       "$a$"))))))

(ert-deftest org-latex-to-svg-clears-overlays ()
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ $b$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (= 2 (length (org-latex-to-svg-tests--overlays))))
      (org-latex-to-svg--clear-region (point-min) (point-max))
      (should (null (org-latex-to-svg-tests--overlays))))))

(ert-deftest org-latex-to-svg-overlay-reveals-on-edit ()
  ;; Editing under an overlay reveals the source (hides the image) and flags
  ;; the overlay for re-render, but keeps it (so leaving can restore/redraw).
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (= 1 (length (org-latex-to-svg-tests--overlays))))
      (goto-char (+ (point-min) 1))     ; inside the fragment
      (insert "x")
      (let ((ov (car (org-latex-to-svg-tests--overlays))))
        (should ov)
        (should (null (overlay-get ov 'display)))            ; image hidden
        (should (overlay-get ov 'org-latex-to-svg-modified))))))

(ert-deftest org-latex-to-svg-reveals-preview-under-cursor ()
  ;; Point entering an image preview reveals its source; leaving (unmodified)
  ;; re-shows the image.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ after\n"
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      (let ((ov (car (org-latex-to-svg-tests--overlays))))
        ;; Move into the fragment -> revealed (image hidden).
        (goto-char (+ (point-min) 1))
        (org-latex-to-svg--handle-cursor)
        (should (null (overlay-get ov 'display)))
        ;; Move out -> the overlay left at the previous point is closed,
        ;; restoring its image.
        (goto-char (point-max))
        (org-latex-to-svg--handle-cursor)
        (should (eq (overlay-get ov 'display) 'fake-image))))))

(ert-deftest org-latex-to-svg-cursor-jump-between-previews ()
  ;; Jumping straight from one preview into another closes the first
  ;; (restores its image) and reveals the second — the previous-point close
  ;; handles it without a tracked-overlay reference.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ $b$\n"
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      (let ((ovs (org-latex-to-svg-tests--overlays)))
        (goto-char (+ (point-min) 1))            ; into $a$
        (org-latex-to-svg--handle-cursor)
        (should (null (overlay-get (nth 0 ovs) 'display)))
        (goto-char (overlay-start (nth 1 ovs)))  ; jump into $b$
        (org-latex-to-svg--handle-cursor)
        (should (eq (overlay-get (nth 0 ovs) 'display) 'fake-image)) ; a restored
        (should (null (overlay-get (nth 1 ovs) 'display)))))))         ; b revealed

(ert-deftest org-latex-to-svg-heal-rerenders-left-edit ()
  ;; Backstop: a fragment edited then left by point (without a clean cursor
  ;; leave) is re-rendered by `--heal-modified'.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ after\n"
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      (goto-char (+ (point-min) 1))
      (insert "b")                                 ; edit -> modified + revealed
      (goto-char (point-max))                      ; point already outside
      (let ((org-latex-to-svg-tests--image 'healed))
        (org-latex-to-svg--heal-modified))
      (let ((ov (car (org-latex-to-svg-tests--overlays))))
        (should (eq (overlay-get ov 'display) 'healed))
        (should (equal (overlay-get ov 'org-latex-to-svg-value) "$ba$"))
        (should-not (overlay-get ov 'org-latex-to-svg-modified))))))

(ert-deftest org-latex-to-svg-heal-leaves-fragment-under-point ()
  ;; A fragment still under point (being edited) is NOT healed — stays revealed.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ after\n"
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      (goto-char (+ (point-min) 1))
      (insert "b")                                 ; point stays inside
      (org-latex-to-svg--heal-modified)
      (let ((ov (car (org-latex-to-svg-tests--overlays))))
        (should (null (overlay-get ov 'display)))            ; still revealed
        (should (overlay-get ov 'org-latex-to-svg-modified))))))

(ert-deftest org-latex-to-svg-rerenders-after-reveal-edit ()
  ;; Editing while revealed then leaving re-renders the fragment (fresh image).
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ after\n"
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      (goto-char (+ (point-min) 1))
      (org-latex-to-svg--handle-cursor)            ; reveal
      (insert "b")                                  ; edit -> modified
      (let ((org-latex-to-svg-tests--image 'redrawn))
        (goto-char (point-max))
        (org-latex-to-svg--handle-cursor))         ; leave -> re-render
      (let ((ov (car (org-latex-to-svg-tests--overlays))))
        (should (eq (overlay-get ov 'display) 'redrawn))
        (should (equal (overlay-get ov 'org-latex-to-svg-value) "$ba$"))))))

(ert-deftest org-latex-to-svg-render-replaces-existing-overlay ()
  ;; Re-rendering the same span doesn't stack overlays.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (= 1 (length (org-latex-to-svg-tests--overlays)))))))

;;;; Command

(ert-deftest org-latex-to-svg-command-toggles-at-point ()
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ text\n"
      (goto-char (+ (point-min) 1))     ; on the fragment
      (org-latex-to-svg)                ; render it
      (should (= 1 (length (org-latex-to-svg-tests--overlays))))
      (goto-char (+ (point-min) 1))
      (org-latex-to-svg)                ; toggle off
      (should (null (org-latex-to-svg-tests--overlays))))))

(ert-deftest org-latex-to-svg-command-rerenders-with-prefix ()
  ;; `C-u' clears and re-renders the buffer (rebuilding overlays from cache) —
  ;; changing the stub image proves the overlays were actually rebuilt.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ $b$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (= 2 (length (org-latex-to-svg-tests--overlays))))
      (let ((org-latex-to-svg-tests--image 'rebuilt))
        (org-latex-to-svg '(4)))        ; C-u => clear + render
      (let ((ovs (org-latex-to-svg-tests--overlays)))
        (should (= 2 (length ovs)))
        (should (cl-every (lambda (o) (eq (overlay-get o 'display) 'rebuilt)) ovs))))))

(ert-deftest org-latex-to-svg-command-regenerates-with-double-prefix ()
  ;; `C-u C-u' invalidates each equation's cached SVG, then re-renders.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ \\[b\\]\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (org-latex-to-svg '(16))          ; C-u C-u => regenerate
      ;; Both equations were invalidated (order-independent).
      (should (equal (sort (copy-sequence org-latex-to-svg-tests--invalidated)
                           #'string<)
                     '("$a$" "\\[b\\]")))
      (should (= 2 (length (org-latex-to-svg-tests--overlays)))))))

(ert-deftest org-latex-to-svg-clear-command ()
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ $b$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (= 2 (length (org-latex-to-svg-tests--overlays))))
      (org-latex-to-svg-clear)
      (should (null (org-latex-to-svg-tests--overlays))))))

(ert-deftest org-latex-to-svg-regenerate-command ()
  ;; `org-latex-to-svg-regenerate' invalidates the cache per element and leaves
  ;; fresh overlays in place.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (let ((org-latex-to-svg-tests--image 'fresh))
        (org-latex-to-svg-regenerate))
      (should (equal org-latex-to-svg-tests--invalidated '("$a$")))
      (let ((ovs (org-latex-to-svg-tests--overlays)))
        (should (= 1 (length ovs)))
        (should (eq (overlay-get (car ovs) 'display) 'fresh))))))

;;;; Minor mode

(ert-deftest org-latex-to-svg-mode-renders-and-clears ()
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ \\[b\\]\n"
      (org-latex-to-svg-mode 1)
      (should (= 2 (length (org-latex-to-svg-tests--overlays))))
      (org-latex-to-svg-mode -1)
      (should (null (org-latex-to-svg-tests--overlays))))))

(ert-deftest org-latex-to-svg-mode-refuses-non-org ()
  (with-temp-buffer
    (fundamental-mode)
    (should-error (org-latex-to-svg-mode 1))
    (should-not org-latex-to-svg-mode)))

;;;; Refresh

(ert-deftest org-latex-to-svg-refresh-updates-image ()
  ;; A refresh re-fetches each overlay's image from the engine — simulating a
  ;; theme change by rebinding what the stub returns — and updates `display'.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (eq (overlay-get (car (org-latex-to-svg-tests--overlays)) 'display)
                  'fake-image))
      (let ((org-latex-to-svg-tests--image 'retinted-image))
        (org-latex-to-svg-refresh))
      (should (eq (overlay-get (car (org-latex-to-svg-tests--overlays)) 'display)
                  'retinted-image)))))

(ert-deftest org-latex-to-svg-refresh-if-changed-gated-on-appearance ()
  ;; `--refresh-if-changed' only re-renders when the appearance signature
  ;; differs from the one recorded at render time.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$\n"
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      ;; Same appearance => no change (stub image stays the same object).
      (let ((org-latex-to-svg-tests--image 'should-not-apply))
        (org-latex-to-svg--refresh-if-changed)
        (should (eq (overlay-get (car (org-latex-to-svg-tests--overlays)) 'display)
                    'fake-image)))
      ;; Appearance changes => refresh applies the new image.
      (setq org-latex-to-svg-tests--appearance '("#fff" "#000" 28))
      (let ((org-latex-to-svg-tests--image 'applied))
        (org-latex-to-svg--refresh-if-changed)
        (should (eq (overlay-get (car (org-latex-to-svg-tests--overlays)) 'display)
                    'applied))))))

;;;; Numbering

(ert-deftest org-latex-to-svg-counts-single-environments ()
  ;; A single-equation environment consumes 1, its starred form 0, and a
  ;; \nonumber / \notag / \tag suppresses the number.
  (should (= 1 (org-latex-to-svg--count-numbered-equations
                "\\begin{equation}\nx=1\n\\end{equation}\n")))
  (should (= 0 (org-latex-to-svg--count-numbered-equations
                "\\begin{equation*}\nx=1\n\\end{equation*}\n")))
  (should (= 0 (org-latex-to-svg--count-numbered-equations
                "\\begin{equation}\nx=1\\nonumber\n\\end{equation}\n"))))

(ert-deftest org-latex-to-svg-multline-consumes-one ()
  ;; `multline' is a single number for the whole line-broken equation, so its
  ;; internal `\\' must NOT be counted as separate equations.
  (should (= 1 (org-latex-to-svg--count-numbered-equations
                "\\begin{multline}\na\\\\b\\\\c\n\\end{multline}\n"))))

(ert-deftest org-latex-to-svg-counts-multi-rows ()
  ;; `align' consumes one per row, minus \nonumber rows.
  (should (= 3 (org-latex-to-svg--count-numbered-equations
                "\\begin{align}\na&=b\\\\\nc&=d\\\\\ne&=f\n\\end{align}\n")))
  (should (= 2 (org-latex-to-svg--count-numbered-equations
                "\\begin{align}\na&=b\\\\\nc&=d\\nonumber\\\\\ne&=f\n\\end{align}\n"))))

(ert-deftest org-latex-to-svg-nested-rows-not-counted ()
  ;; `\\' inside a nested environment (matrix/cases/…) are line breaks, not
  ;; align rows, so they must be stripped before counting.
  (should (= 2 (org-latex-to-svg--count-numbered-equations
                (concat "\\begin{align}\n"
                        "x&=\\begin{pmatrix}a\\\\b\\end{pmatrix}\\\\\n"
                        "y&=2\n"
                        "\\end{align}\n")))))

(ert-deftest org-latex-to-svg-numbering-table-threads-offsets ()
  ;; Offsets are the count of preceding numbered equations: equation (1) then
  ;; a two-row align (2) then equation => offsets 0, 1, 3.
  (org-latex-to-svg-tests--org
      (concat "\\begin{equation}\na\n\\end{equation}\n\n"
              "\\begin{align}\nb&=1\\\\\nc&=2\n\\end{align}\n\n"
              "\\begin{equation}\nd\n\\end{equation}\n")
    (let* ((table (org-latex-to-svg--numbering-table))
           (offsets (org-element-map (org-element-parse-buffer)
                        'latex-environment
                      (lambda (el) (gethash (org-element-property :begin el)
                                            table)))))
      (should (equal offsets '(0 1 3))))))

(ert-deftest org-latex-to-svg-bakes-setcounter-into-overlay ()
  ;; With numbering on, an environment's rendered (and cached) value carries a
  ;; `\setcounter' prefix with the right offset; a fragment never does.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org
        (concat "$a$\n\n\\begin{equation}\nx\n\\end{equation}\n\n"
                "\\begin{equation}\ny\n\\end{equation}\n")
      (let ((org-latex-to-svg-number-equations t))
        (org-latex-to-svg--render-region (point-min) (point-max)))
      (let ((values (mapcar (lambda (o) (overlay-get o 'org-latex-to-svg-value))
                            (org-latex-to-svg-tests--overlays))))
        ;; Fragment: unchanged.
        (should (equal (nth 0 values) "$a$"))
        ;; First equation: offset 0.
        (should (string-prefix-p "\\setcounter{equation}{0}%\n\\begin{equation}"
                                 (nth 1 values)))
        ;; Second equation: offset 1.
        (should (string-prefix-p "\\setcounter{equation}{1}%\n\\begin{equation}"
                                 (nth 2 values)))))))

(ert-deftest org-latex-to-svg-help-echo-is-plain-source ()
  ;; The tooltip shows the plain LaTeX, not the \setcounter-prefixed input.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "\\begin{equation}\nx\n\\end{equation}\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (let ((ov (car (org-latex-to-svg-tests--overlays))))
        (should (equal (overlay-get ov 'help-echo)
                       "\\begin{equation}\nx\n\\end{equation}\n"))
        (should-not (string-match-p "setcounter" (overlay-get ov 'help-echo)))))))

(ert-deftest org-latex-to-svg-numbering-can-be-disabled ()
  ;; With numbering off, environments render verbatim (no \setcounter).
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "\\begin{equation}\nx\n\\end{equation}\n"
      (let ((org-latex-to-svg-number-equations nil))
        (org-latex-to-svg--render-region (point-min) (point-max)))
      (let ((ov (car (org-latex-to-svg-tests--overlays))))
        (should (equal (overlay-get ov 'org-latex-to-svg-value)
                       "\\begin{equation}\nx\n\\end{equation}\n"))))))

(ert-deftest org-latex-to-svg-regenerate-invalidates-numbered-value ()
  ;; Regenerate must invalidate the *prefixed* string (the real cache key), not
  ;; the bare source, so the right hash is dropped.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "\\begin{equation}\nx\n\\end{equation}\n"
      (let ((org-latex-to-svg-number-equations t))
        (org-latex-to-svg--render-region (point-min) (point-max))
        (org-latex-to-svg-regenerate))
      (should (equal org-latex-to-svg-tests--invalidated
                     '("\\setcounter{equation}{0}%\n\\begin{equation}\nx\n\\end{equation}\n\\typeout{L2S=\\arabic{equation}}%\n"))))))

(ert-deftest org-latex-to-svg-reconcile-updates-downstream ()
  ;; Turning an equation into its starred form drops its number; a reconcile
  ;; must renumber the equation below from offset 1 to 0.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\nb\n\\end{equation}\n")
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (string-prefix-p
               "\\setcounter{equation}{1}%"
               (overlay-get (nth 1 (org-latex-to-svg-tests--overlays))
                            'org-latex-to-svg-value)))
      ;; Edit eq1 into equation* (its overlay clears on modification).
      (goto-char (point-min))
      (search-forward "\\begin{equation}") (backward-char 1) (insert "*")
      (search-forward "\\end{equation}") (backward-char 1) (insert "*")
      (org-latex-to-svg--reconcile)
      ;; eq1 is now unnumbered (equation*); eq2 renumbers from offset 1 to 0.
      (let ((ovs (org-latex-to-svg-tests--overlays)))
        (should (string-prefix-p
                 "\\setcounter{equation}{0}%"
                 (overlay-get (car (last ovs)) 'org-latex-to-svg-value)))))))

(ert-deftest org-latex-to-svg-reconcile-uses-ground-truth-consumed ()
  ;; When an overlay's `.eld' metadata says a block consumed more numbers than
  ;; the heuristic guessed, the reconcile threads the ground-truth count: the
  ;; block below is re-rendered at the corrected K.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\nb\n\\end{equation}\n")
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      ;; Pretend eq1 actually consumed TWO numbers (INITIAL 1 . FINAL 2).
      (overlay-put (nth 0 (org-latex-to-svg-tests--overlays))
                   'org-latex-to-svg-enums '(1 . 2))
      (org-latex-to-svg--reconcile)
      ;; eq2 must move from K=1 to K=2.
      (should (string-prefix-p
               "\\setcounter{equation}{2}%"
               (overlay-get (nth 1 (org-latex-to-svg-tests--overlays))
                            'org-latex-to-svg-value))))))

;;;; Inline / display rescale

(ert-deftest org-latex-to-svg-classifies-display-vs-inline ()
  (should-not (org-latex-to-svg--display-p "$x$"))
  (should-not (org-latex-to-svg--display-p "\\(x\\)"))
  (should (org-latex-to-svg--display-p "\\[x\\]"))
  (should (org-latex-to-svg--display-p "$$x$$"))
  (should (org-latex-to-svg--display-p "\\begin{equation}x\\end{equation}\n")))

(ert-deftest org-latex-to-svg-passes-inline-and-display-rescale ()
  ;; Each element is rendered with the size multiplier for its kind.
  (org-latex-to-svg-tests--with-stub
    (let ((org-latex-to-svg-inline-rescale 1.0)
          (org-latex-to-svg-display-rescale 1.4)
          (org-latex-to-svg-number-equations nil))
      (org-latex-to-svg-tests--org "inline $a$ end\n"
        (org-latex-to-svg--render-region (point-min) (point-max))
        (should (equal org-latex-to-svg-tests--last-rescale 1.0)))
      (org-latex-to-svg-tests--org "\\[b\\]\n"
        (org-latex-to-svg--render-region (point-min) (point-max))
        (should (equal org-latex-to-svg-tests--last-rescale 1.4))))))

(ert-deftest org-latex-to-svg-refresh-rescales-by-kind ()
  ;; A refresh re-fetches each overlay at its own inline/display factor.
  (org-latex-to-svg-tests--with-stub
    (let ((org-latex-to-svg-inline-rescale 1.0)
          (org-latex-to-svg-display-rescale 1.4)
          (org-latex-to-svg-number-equations nil))
      (org-latex-to-svg-tests--org "\\[b\\]\n"
        (org-latex-to-svg--render-region (point-min) (point-max))
        (let ((ov (car (org-latex-to-svg-tests--overlays))))
          (should (overlay-get ov 'org-latex-to-svg-display-math))
          (setq org-latex-to-svg-tests--last-rescale nil)
          (org-latex-to-svg-refresh)
          (should (equal org-latex-to-svg-tests--last-rescale 1.4)))))))

;;;; \eqref / \ref

(ert-deftest org-latex-to-svg-scan-harvests-labels ()
  ;; The scan resolves \label names to numbers: a single equation (1), then a
  ;; two-row align whose rows are labelled (2, 3).
  (org-latex-to-svg-tests--org
      (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
              "\\begin{align}\ny&=1\\label{eq:b}\\\\\nz&=2\\label{eq:c}\n\\end{align}\n")
    (let ((labels (cdr (org-latex-to-svg--scan-numbering))))
      (should (= 1 (gethash "eq:a" labels)))
      (should (= 2 (gethash "eq:b" labels)))
      (should (= 3 (gethash "eq:c" labels))))))

(ert-deftest org-latex-to-svg-nonumber-row-label-skipped ()
  ;; A \nonumber row doesn't advance the counter, and its label stays unresolved.
  (org-latex-to-svg-tests--org
      (concat "\\begin{align}\n"
              "a&=1\\label{eq:x}\\\\\n"
              "b&=2\\nonumber\\label{eq:y}\\\\\n"
              "c&=3\\label{eq:z}\n"
              "\\end{align}\n")
    (let ((labels (cdr (org-latex-to-svg--scan-numbering))))
      (should (= 1 (gethash "eq:x" labels)))
      (should (null (gethash "eq:y" labels)))
      (should (= 2 (gethash "eq:z" labels))))))

(ert-deftest org-latex-to-svg-reference-display-renders ()
  ;; \eqref -> "(N)", \ref -> "N" as plain text, wrapped forms too; unknown -> nil.
  (let ((labels (make-hash-table :test 'equal)))
    (puthash "eq:a" 7 labels)
    (should (equal "(7)" (org-latex-to-svg--reference-display "\\eqref{eq:a}" labels)))
    (should (equal "7"   (org-latex-to-svg--reference-display "\\ref{eq:a}" labels)))
    (should (equal "(7)" (org-latex-to-svg--reference-display "$\\eqref{eq:a}$" labels)))
    (should (equal "(7)" (org-latex-to-svg--reference-display "\\(\\eqref{eq:a}\\)" labels)))
    (should (null (org-latex-to-svg--reference-display "\\eqref{eq:missing}" labels)))
    (should (null (org-latex-to-svg--reference-display "$x=1$" labels)))))

(ert-deftest org-latex-to-svg-renders-eqref-as-text ()
  ;; End to end: an \eqref fragment overlays with plain text `(N)' (no LaTeX
  ;; image / cached value) and is marked click-to-jump for its label.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org
        (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
                "As in \\eqref{eq:a}.\n")
      (org-latex-to-svg--render-region (point-min) (point-max))
      (let* ((ovs (org-latex-to-svg-tests--overlays))
             (ref (car (last ovs))))
        (should (equal (substring-no-properties (overlay-get ref 'display)) "(1)"))
        (should (null (overlay-get ref 'org-latex-to-svg-value)))
        (should (equal (overlay-get ref 'org-latex-to-svg-ref) "eq:a"))
        (should (eq (overlay-get ref 'keymap)
                    org-latex-to-svg--reference-keymap))))))

(ert-deftest org-latex-to-svg-label-position-finds-defining-element ()
  (org-latex-to-svg-tests--org
      (concat "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n\n"
              "\\begin{align}\ny&=1\\label{eq:b}\\\\\nz&=2\n\\end{align}\n")
    ;; Each label resolves to the :begin of the environment that defines it.
    (should (= (org-latex-to-svg--label-position "eq:a") (point-min)))
    (let ((align-begin (save-excursion (goto-char (point-min))
                                       (search-forward "\\begin{align}")
                                       (match-beginning 0))))
      (should (= (org-latex-to-svg--label-position "eq:b") align-begin)))
    (should (null (org-latex-to-svg--label-position "eq:missing")))))

(ert-deftest org-latex-to-svg-goto-reference-jumps-to-target ()
  ;; Invoking the jump command over an \eqref preview moves point to the
  ;; equation that defines the label.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org
        (concat "See \\eqref{eq:a}.\n\n"
                "\\begin{equation}\\label{eq:a}\nx\n\\end{equation}\n")
      (org-latex-to-svg--render-region (point-min) (point-max))
      (let* ((ref (seq-find (lambda (o) (overlay-get o 'org-latex-to-svg-ref))
                            (org-latex-to-svg-tests--overlays)))
             (target (save-excursion (goto-char (point-min))
                                     (search-forward "\\begin{equation}")
                                     (match-beginning 0))))
        (goto-char (overlay-start ref))
        (org-latex-to-svg-goto-reference)
        (should (= (point) target))))))

(ert-deftest org-latex-to-svg-eqref-follows-renumber ()
  ;; A downstream \eqref updates when the target equation renumbers: two
  ;; equations, \eqref{eq:b} -> (2); delete the first equation's number so the
  ;; second becomes (1) and the reference re-renders to $(1)$.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org
        (concat "\\begin{equation}\na\n\\end{equation}\n\n"
                "\\begin{equation}\\label{eq:b}\nb\n\\end{equation}\n\n"
                "See \\eqref{eq:b}.\n")
      (setq-local org-latex-to-svg-mode t)
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (equal "(2)"
                     (substring-no-properties
                      (overlay-get (car (last (org-latex-to-svg-tests--overlays)))
                                   'display))))
      ;; Turn the first equation into equation* (its overlay clears on edit).
      (goto-char (point-min))
      (search-forward "\\begin{equation}") (backward-char 1) (insert "*")
      (search-forward "\\end{equation}") (backward-char 1) (insert "*")
      (org-latex-to-svg--reconcile)
      (should (equal "(1)"
                     (substring-no-properties
                      (overlay-get (car (last (org-latex-to-svg-tests--overlays)))
                                   'display)))))))

(provide 'org-latex-to-svg-tests)

;;; org-latex-to-svg-tests.el ends here
