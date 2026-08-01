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
  `(let ((org-latex-to-svg-tests--appearance '("#000" "#fff" 20)))
     (cl-letf (((symbol-function 'latex-to-svg)
                (lambda (_latex &rest _) org-latex-to-svg-tests--image))
               ((symbol-function 'latex-to-svg-appearance)
                (lambda () org-latex-to-svg-tests--appearance))
               ((symbol-function 'latex-to-svg-flush-metrics) #'ignore))
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

(ert-deftest org-latex-to-svg-overlay-clears-on-edit ()
  ;; Editing under an overlay drops it (revealing the source) via its
  ;; modification hook.
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (= 1 (length (org-latex-to-svg-tests--overlays))))
      (goto-char (+ (point-min) 1))     ; inside the fragment
      (insert "x")
      (should (null (org-latex-to-svg-tests--overlays))))))

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

(ert-deftest org-latex-to-svg-command-clears-with-prefix ()
  (org-latex-to-svg-tests--with-stub
    (org-latex-to-svg-tests--org "$a$ $b$\n"
      (org-latex-to-svg--render-region (point-min) (point-max))
      (should (= 2 (length (org-latex-to-svg-tests--overlays))))
      (org-latex-to-svg '(4))           ; C-u => clear buffer
      (should (null (org-latex-to-svg-tests--overlays))))))

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

(provide 'org-latex-to-svg-tests)

;;; org-latex-to-svg-tests.el ends here
