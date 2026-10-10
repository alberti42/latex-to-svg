;;; emacs-faces-check.el --- Compare Emacs's face reader with our copy  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; `latex-to-svg-frontend--text-foreground' follows Emacs's
;; `foreground-color-at-point' and `faces--attribute-at-point'.
;; `tests/fixtures/emacs-faces-attribute-at-point.el' holds a copy of
;; the two.  This script reads both definitions from the source of the
;; Emacs that runs it and from the copy, drops their docstrings (reading
;; them drops comments and whitespace), and compares them.  When they
;; differ, it prints a unified diff and exits with status 1; when it
;; cannot find the source, with status 2.
;;
;;   emacs -Q -batch -l scripts/emacs-faces-check.el
;;
;; CI runs it on Emacs snapshot, in a job that is allowed to fail.

;;; Code:

(require 'find-func)
(require 'pp)

(defconst emacs-faces-check-functions
  '(faces--attribute-at-point foreground-color-at-point)
  "The functions of faces.el compared with the copy.")

(defconst emacs-faces-check-copy
  (expand-file-name "../tests/fixtures/emacs-faces-attribute-at-point.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The file that holds the copy.")

(defun emacs-faces-check--without-docstring (form)
  "Return the `defun' FORM without its docstring."
  (if (and (eq (car-safe form) 'defun) (stringp (nth 3 form)))
      (append (seq-take form 3) (nthcdr 4 form))
    form))

(defun emacs-faces-check--read-defun (function buffer)
  "Return the `defun' of FUNCTION read from BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward
             (format "^(defun %s[ \n]" (regexp-quote (symbol-name function)))
             nil t)
        (goto-char (match-beginning 0))
        (read (current-buffer))))))

(defun emacs-faces-check--emacs-defun (function)
  "Return the `defun' of FUNCTION read from the source of this Emacs, or nil."
  (when-let* ((found (ignore-errors (find-function-noselect function t))))
    (with-current-buffer (car found)
      (save-excursion
        (goto-char (cdr found))
        (read (current-buffer))))))

(defun emacs-faces-check--diff (expected actual)
  "Return a unified diff of the forms EXPECTED and ACTUAL, as a string."
  (let ((old (make-temp-file "faces-copy-" nil ".el" (pp-to-string expected)))
        (new (make-temp-file "faces-emacs-" nil ".el" (pp-to-string actual))))
    (unwind-protect
        (with-temp-buffer
          (call-process "diff" nil t nil "-u"
                        "--label" "copy (tests/fixtures)" "--label"
                        (format "Emacs %s" emacs-version) old new)
          (buffer-string))
      (delete-file old)
      (delete-file new))))

(defun emacs-faces-check ()
  "Compare `emacs-faces-check-functions' with the copy; exit with a status."
  (let ((copy (find-file-noselect emacs-faces-check-copy))
        (status 0))
    (dolist (function emacs-faces-check-functions)
      (let ((expected (emacs-faces-check--read-defun function copy))
            (actual (emacs-faces-check--emacs-defun function)))
        (cond
         ((null expected)
          (message "%s: not in %s" function emacs-faces-check-copy)
          (setq status 2))
         ((null actual)
          (message "%s: no source found in Emacs %s" function emacs-version)
          (setq status (max status 2)))
         ((equal (emacs-faces-check--without-docstring expected)
                 (emacs-faces-check--without-docstring actual))
          (message "%s: same as the copy in Emacs %s" function emacs-version))
         (t
          (message "%s: differs from the copy in Emacs %s:\n%s"
                   function emacs-version
                   (emacs-faces-check--diff
                    (emacs-faces-check--without-docstring expected)
                    (emacs-faces-check--without-docstring actual)))
          (setq status (if (= status 2) 2 1))))))
    (kill-emacs status)))

(emacs-faces-check)

;;; emacs-faces-check.el ends here
