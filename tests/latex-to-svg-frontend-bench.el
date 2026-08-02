;;; latex-to-svg-frontend-bench.el --- Scan/exclusion/reconcile timings  -*- lexical-binding: t; -*-

;; Not part of the test suite.  Load into a live Emacs that has the
;; Markdown tree-sitter grammar and the adaptors, then call
;; `l2sf-bench-run' (Markdown) or `l2sf-bench-run-org'.
;;
;; It isolates the pieces of one whole-buffer reconcile:
;;   - exclusions     : the buffer-local `--exclude-function' (tree-sitter +
;;                      inline-code regexp for Markdown; block scan for Org)
;;   - regexp sweep   : the raw `re-search-forward' opener pass, no filtering
;;   - scan           : `--scan' (exclusions + regexp + `--in-code-p' + span)
;;   - environments   : `--environments' (scan + type filter)
;;   - scan-numbering : label/offset table build
;;   - reconcile      : end-to-end `--reconcile' (no overlays => no compile)
;;
;; No engine calls: we install the exclude-function and set the mode flags
;; by hand and never render, so nothing hits `latex-to-svg-backend'.

(require 'latex-to-svg-frontend)
(require 'latex-to-svg-for-markdown nil t)
(require 'latex-to-svg-for-org nil t)
(require 'benchmark)

(defun l2sf-bench--md-doc (n)
  "Return a Markdown string with N numbered equations and a realistic mix
of prose, fenced code, inline code, inline math, and references."
  (let ((parts '()))
    (dotimes (i n)
      (push (format "## Section %d

Some prose with inline math $a_%d + b$ and a reference to \\eqref{eq:%d}
and \\ref{eq:%d}, plus an inline `code_span_%d` token in the sentence.

```python
def f_%d(x):
    return x * %d  # fenced code, must be excluded
```

More prose with a bracketed fragment \\(x_%d^2\\) inline in the line.

\\begin{equation}
\\label{eq:%d}
E_%d = m c^2 + \\sum_{k=0}^{%d} k
\\end{equation}
"
                    i i i i i i i i i i (max 1 i))
            parts))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun l2sf-bench--org-doc (n)
  "Return an Org string analogous to `l2sf-bench--md-doc'."
  (let ((parts '()))
    (dotimes (i n)
      (push (format "* Section %d

Some prose with inline math $a_%d + b$ and a reference to \\eqref{eq:%d}.

#+begin_src python
def f_%d(x):
    return x * %d  # src block, must be excluded
#+end_src

More prose with a bracketed fragment \\(x_%d^2\\) inline.

\\begin{equation}
\\label{eq:%d}
E_%d = m c^2 + \\sum_{k=0}^{%d} k
\\end{equation}
"
                    i i i i i i i i (max 1 i))
            parts))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun l2sf-bench--regexp-count ()
  "Raw opener sweep with no filtering; return the match count (times the sweep)."
  (let ((c 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward latex-to-svg-frontend--opener-regexp nil t)
        (setq c (1+ c))))
    c))

(defun l2sf-bench--ms (form-thunk reps)
  "Return average milliseconds over REPS calls of FORM-THUNK."
  (let ((res (benchmark-call form-thunk reps)))
    ;; `benchmark-call' returns (TOTAL-SECONDS GCS GC-SECONDS).
    (* 1000.0 (/ (car res) (float reps)))))

(defun l2sf-bench--one (n reps warmup-p)
  "Benchmark buffer already set up in the current buffer with N equations."
  (let* ((full (buffer-string))
         (chars (length full))
         (lines (count-lines (point-min) (point-max)))
         ;; Warm the tree-sitter parser so we measure query, not first parse.
         (_ (when warmup-p (latex-to-svg-frontend--exclusions (point-min) (point-max))))
         (nopen (l2sf-bench--regexp-count))
         (nregions (length (latex-to-svg-frontend--exclusions
                            (point-min) (point-max))))
         (t-excl (l2sf-bench--ms
                  (lambda () (latex-to-svg-frontend--exclusions
                              (point-min) (point-max))) reps))
         (t-re   (l2sf-bench--ms #'l2sf-bench--regexp-count reps))
         (t-scan (l2sf-bench--ms
                  (lambda () (latex-to-svg-frontend--scan)) reps))
         (t-env  (l2sf-bench--ms
                  (lambda () (latex-to-svg-frontend--environments)) reps))
         (t-num  (l2sf-bench--ms
                  (lambda () (latex-to-svg-frontend--scan-numbering)) reps))
         (t-rec  (l2sf-bench--ms
                  (lambda () (latex-to-svg-frontend--reconcile)) reps)))
    (format (concat "n=%-5d chars=%-8d lines=%-6d openers=%-5d regions=%-5d | "
                    "excl=%.2f  regexp=%.2f  scan=%.2f  env=%.2f  "
                    "num=%.2f  reconcile=%.2f  (ms, avg of %d)")
            n chars lines nopen nregions
            t-excl t-re t-scan t-env t-num t-rec reps)))

(defun l2sf-bench-run (&optional sizes reps)
  "Benchmark the Markdown path across SIZES (default 100 250 500 1000)."
  (let ((sizes (or sizes '(100 250 500 1000)))
        (reps (or reps 10))
        (out '()))
    (dolist (n sizes)
      (with-temp-buffer
        (insert (l2sf-bench--md-doc n))
        (delay-mode-hooks
          (if (fboundp 'markdown-ts-mode) (markdown-ts-mode) (fundamental-mode)))
        (setq-local latex-to-svg-frontend-exclude-function
                    #'latex-to-svg-for-markdown--exclusions)
        (setq-local latex-to-svg-frontend-mode t)
        (setq-local latex-to-svg-frontend-number-equations t)
        (push (l2sf-bench--one n reps t) out)))
    (concat "\n== Markdown ==\n" (mapconcat #'identity (nreverse out) "\n") "\n")))

(defun l2sf-bench-run-org (&optional sizes reps)
  "Benchmark the Org path across SIZES (default 100 250 500 1000)."
  (let ((sizes (or sizes '(100 250 500 1000)))
        (reps (or reps 10))
        (out '()))
    (dolist (n sizes)
      (with-temp-buffer
        (insert (l2sf-bench--org-doc n))
        (delay-mode-hooks (org-mode))
        (setq-local latex-to-svg-frontend-exclude-function
                    #'latex-to-svg-for-org--exclusions)
        (setq-local latex-to-svg-frontend-mode t)
        (setq-local latex-to-svg-frontend-number-equations t)
        (push (l2sf-bench--one n reps nil) out)))
    (concat "\n== Org ==\n" (mapconcat #'identity (nreverse out) "\n") "\n")))

(defun l2sf-bench-leave (&optional sizes reps)
  "Benchmark the cursor-leave reconcile: incremental vs full, across SIZES.
Stubs the engine (instant dummy image) so overlays exist without a compile,
renders the whole buffer, then times a full `--reconcile' against
`--reconcile-from' for an in-place edit near the TOP (no count change, so
the incremental pass early-exits) and near the BOTTOM."
  (let ((sizes (or sizes '(100 250 500 1000)))
        (reps (or reps 20))
        (out '()))
    (cl-letf (((symbol-function 'latex-to-svg-backend)
               (lambda (&rest _) 'bench-image))
              ((symbol-function 'latex-to-svg-backend-metadata) (lambda (_) nil)))
      (dolist (n sizes)
        (with-temp-buffer
          (insert (l2sf-bench--md-doc n))
          (delay-mode-hooks
            (if (fboundp 'markdown-ts-mode) (markdown-ts-mode) (fundamental-mode)))
          (setq-local latex-to-svg-frontend-exclude-function
                      #'latex-to-svg-for-markdown--exclusions)
          (setq-local latex-to-svg-frontend-mode t)
          (setq-local latex-to-svg-frontend-number-equations t)
          (latex-to-svg-frontend--exclusions (point-min) (point-max)) ; warm parser
          (latex-to-svg-frontend--render-region (point-min) (point-max))
          (let* ((ovs (latex-to-svg-frontend--numbered-overlays))
                 (top (overlay-start (nth 1 ovs)))
                 (bot (overlay-start (car (last ovs))))
                 (t-full (l2sf-bench--ms
                          (lambda () (latex-to-svg-frontend--reconcile)) reps))
                 (t-top  (l2sf-bench--ms
                          (lambda () (latex-to-svg-frontend--reconcile-from top))
                          reps))
                 (t-bot  (l2sf-bench--ms
                          (lambda () (latex-to-svg-frontend--reconcile-from bot))
                          reps)))
            (push (format (concat "n=%-5d openers=%-5d | full=%.2f  "
                                  "from-top=%.2f  from-bottom=%.2f  "
                                  "(ms, avg of %d)")
                          n (length ovs) t-full t-top t-bot reps)
                  out)))))
    (concat "\n== Leave reconcile (Markdown) ==\n"
            (mapconcat #'identity (nreverse out) "\n") "\n")))

(provide 'latex-to-svg-frontend-bench)
;;; latex-to-svg-frontend-bench.el ends here
