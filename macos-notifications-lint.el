;;; macos-notifications-lint.el --- Batch lint driver for macos-notifications.el -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Runs checkdoc and (when installed) package-lint over macos-notifications.el and
;; exits non-zero on any finding.  Used by `make lint'.

;;; Code:

(require 'checkdoc)

(defvar macos-notifications-lint--issues 0)

(defun macos-notifications-lint--checkdoc-report (orig text start end &optional unfixable)
  "Count and print checkdoc issue TEXT at START..END, then call ORIG.
UNFIXABLE is passed through to ORIG."
  (setq macos-notifications-lint--issues (1+ macos-notifications-lint--issues))
  (message "checkdoc: %s:%s: %s"
           (buffer-name) (line-number-at-pos start) text)
  (funcall orig text start end unfixable))

(advice-add 'checkdoc-create-error :around #'macos-notifications-lint--checkdoc-report)

(dolist (file '("macos-notifications.el" "macos-notifications-tests.el"))
  (checkdoc-file file))

(require 'package)
(package-initialize)
(if (require 'package-lint nil t)
    (with-current-buffer (find-file-noselect "macos-notifications.el")
      (pcase-dolist (`(,line ,col ,type ,message) (package-lint-buffer))
        (setq macos-notifications-lint--issues (1+ macos-notifications-lint--issues))
        (message "package-lint: macos-notifications.el:%d:%d: %s: %s" line col type message)))
  (message "package-lint not installed, skipping"))

(if (zerop macos-notifications-lint--issues)
    (message "Lint: clean")
  (message "Lint: %d issue(s)" macos-notifications-lint--issues)
  (kill-emacs 1))

(provide 'macos-notifications-lint)
;;; macos-notifications-lint.el ends here
