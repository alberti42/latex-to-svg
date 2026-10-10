;;; emacs-faces-attribute-at-point.el --- Copy of two functions of Emacs's faces.el  -*- lexical-binding: t -*-

;; Copied from GNU Emacs, lisp/faces.el (Copyright (C) 1992-2026 Free
;; Software Foundation, Inc.), under the GNU General Public License
;; version 3 or later.  This file is data, not code: nothing loads it.

;;; Commentary:
;;
;; `latex-to-svg-frontend--text-foreground' follows
;; `foreground-color-at-point', which calls `faces--attribute-at-point'.
;; `scripts/emacs-faces-check.el' compares the two definitions below,
;; without their docstrings, with those of the Emacs that runs it, and
;; prints a diff when they differ.  CI runs it on Emacs snapshot.
;;
;; When it reports a difference: read the diff, decide whether
;; `latex-to-svg-frontend--text-foreground' must follow, then replace the
;; definitions below with the new ones.

;;; Code:

(defun faces--attribute-at-point (attribute &optional attribute-unnamed)
  "Return the face ATTRIBUTE at point.
ATTRIBUTE is a keyword.
If ATTRIBUTE-UNNAMED is non-nil, it is a symbol to look for in
unnamed faces (e.g, `foreground-color')."
  ;; `face-at-point' alone is not sufficient.  It only gets named faces.
  ;; Need also pick up any face properties that are not associated with named faces.
  (let ((faces (or (get-char-property (point) 'read-face-name)
                   ;; If `font-lock-mode' is on, `font-lock-face' takes precedence.
                   (and font-lock-mode
                        (get-char-property (point) 'font-lock-face))
                   (get-char-property (point) 'face)))
        (found nil))
    (dolist (face (if (face-list-p faces)
                      faces
                    (list faces)))
      (cond (found)
            ((and face (symbolp face))
             (let ((value (face-attribute-specified-or
                           (face-attribute face attribute nil t)
                           nil)))
               (unless (member value '(nil "unspecified-fg" "unspecified-bg"))
                 (setq found value))))
            ((consp face)
             (setq found (cond ((and attribute-unnamed
                                     (memq attribute-unnamed face))
                                (cdr (memq attribute-unnamed face)))
                               ((memq attribute face) (cadr (memq attribute face))))))))
    (or found
        (face-attribute 'default attribute))))

(defun foreground-color-at-point ()
  "Return the foreground color of the character after point.
On TTY frames, the returned color name can be \"unspecified-fg\",
which stands for the unknown default foreground color of the
display where the frame is displayed."
  (faces--attribute-at-point :foreground 'foreground-color))

;;; emacs-faces-attribute-at-point.el ends here
