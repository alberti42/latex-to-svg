;;; release-check.el --- Checks to run before tagging a release -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; This file is not part of any package; it is run by hand before a release.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Run from the repository root before tagging a release:
;;
;;   emacs -Q -batch -l scripts/release-check.el
;;
;; It exits non-zero, saying why, unless:
;;
;; - the frontend's `Package-Requires' names the newest `latex-to-svg-backend'
;;   on MELPA Stable.  A user who installed only an adaptor upgrades only that;
;;   package.el upgrades a dependency only when it is below the required
;;   version, so a lower floor leaves them on an old backend;
;; - the newest dated section of CHANGELOG.md is the version in the
;;   `Version:' headers, so the release has its section.
;;
;; The adaptors' floors on the frontend and the equal `Version:' headers are
;; checked by the test suite (tests/latex-to-svg-frontend-tests.el), which
;; needs no network; this script does, for MELPA Stable.

;;; Code:

(require 'lisp-mnt)
(require 'package)
(require 'url)

(defconst release-check-stable-archive
  "https://stable.melpa.org/packages/archive-contents"
  "MELPA Stable's list of packages and their versions.")

(defun release-check--header (file header)
  "Return HEADER of FILE, relative to the repository root."
  (with-temp-buffer
    (insert-file-contents file)
    (lm-header header)))

(defun release-check--required-version (file package)
  "Return the version of PACKAGE that FILE's `Package-Requires' names, or nil."
  (cadr (assq package (car (read-from-string
                            (release-check--header file "package-requires"))))))

(defun release-check--stable-version (package)
  "Return the version of PACKAGE on MELPA Stable, as a string, or nil."
  (with-current-buffer (url-retrieve-synchronously release-check-stable-archive t t 60)
    (goto-char (point-min))
    (re-search-forward "\n\n")
    (let* ((contents (read (current-buffer)))
           (entry (assq package (cdr contents))))
      (kill-buffer)
      (and entry (package-version-join (aref (cdr entry) 0))))))

(defun release-check--changelog-latest ()
  "Return the newest dated version in CHANGELOG.md, or nil."
  (with-temp-buffer
    (insert-file-contents "CHANGELOG.md")
    (and (re-search-forward "^## \\[\\([0-9.]+\\)\\] - " nil t)
         (match-string 1))))

(let* ((version (release-check--header "latex-to-svg-frontend.el" "version"))
       (floor (release-check--required-version "latex-to-svg-frontend.el"
                                               'latex-to-svg-backend))
       (stable (release-check--stable-version 'latex-to-svg-backend))
       (changelog (release-check--changelog-latest))
       (problems '()))
  (message "Release %s" version)
  (message "  backend required by the frontend: %s; newest on MELPA Stable: %s"
           floor stable)
  (message "  newest dated CHANGELOG.md section: %s" changelog)
  (unless stable
    (push "MELPA Stable lists no latex-to-svg-backend" problems))
  (when (and stable (not (equal floor stable)))
    (push (format "latex-to-svg-frontend.el requires latex-to-svg-backend %s, \
but MELPA Stable has %s: raise the floor" floor stable)
          problems))
  (unless (equal changelog version)
    (push (format "CHANGELOG.md's newest dated section is %s, the headers say %s"
                  changelog version)
          problems))
  (if (null problems)
      (message "OK: ready to tag v%s" version)
    (dolist (p (nreverse problems)) (message "FAIL: %s" p))
    (kill-emacs 1)))

;;; release-check.el ends here
