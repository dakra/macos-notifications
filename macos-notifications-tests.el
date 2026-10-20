;;; macos-notifications-tests.el --- Tests for macos-notifications.el -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT test suite.  Run with `make test'.  The click path itself needs a
;; human; see the checklist in PLAN.md.

;;; Code:

(require 'ert)
(require 'macos-notifications)

(defun macos-notifications-tests--run-timers ()
  "Run every pending zero-delay timer."
  (dolist (timer (copy-sequence timer-list))
    (timer-event-handler timer)))

(ert-deftest macos-notifications-tests-filter-dispatch ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending "")
        (calls nil))
    (puthash 12 (lambda (id key) (push (list id key) calls))
             macos-notifications--callbacks)
    (puthash 13 (lambda (id key) (push (list id key) calls))
             macos-notifications--callbacks)
    (macos-notifications--filter nil "12 def")
    (should (equal macos-notifications--pending "12 def"))
    (macos-notifications--filter nil "ault\n13 default\n")
    (should (equal macos-notifications--pending ""))
    (macos-notifications-tests--run-timers)
    (should (equal (nreverse calls) '((12 "default") (13 "default"))))
    (should (zerop (hash-table-count macos-notifications--callbacks)))))

(ert-deftest macos-notifications-tests-callback-error-reported ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending ""))
    (puthash 1 (lambda (_id _key) (error "Boom")) macos-notifications--callbacks)
    (macos-notifications--filter nil "1 default\n")
    (macos-notifications-tests--run-timers)
    (with-current-buffer (messages-buffer)
      (should (string-match-p "callback error: Boom" (buffer-string))))))

(ert-deftest macos-notifications-tests-prune ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--counter 0))
    (dotimes (_ 300)
      (let ((id (cl-incf macos-notifications--counter)))
        (puthash id #'ignore macos-notifications--callbacks)
        (when (zerop (% id 7))
          (remhash id macos-notifications--callbacks))
        (macos-notifications--prune)))
    (let ((keys nil))
      (maphash (lambda (id _) (push id keys)) macos-notifications--callbacks)
      (should (equal (sort keys #'<)
                     (cl-remove-if (lambda (id) (zerop (% id 7)))
                                   (number-sequence 45 300)))))))

(ert-deftest macos-notifications-tests-auth-lines ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending ""))
    (puthash 0 #'ignore macos-notifications--callbacks)
    (macos-notifications--filter nil "auth granted\nauth denied\n")
    (should (= 1 (hash-table-count macos-notifications--callbacks)))
    (with-current-buffer (messages-buffer)
      (should (string-match-p "System Settings" (buffer-string))))))

(ert-deftest macos-notifications-tests-module-loaded ()
  (should (fboundp 'macos-notifications--open)))

(ert-deftest macos-notifications-tests-gui-gate ()
  (should-error (macos-notifications-notify :title "t" :body "b")
                :type 'user-error))

(provide 'macos-notifications-tests)
;;; macos-notifications-tests.el ends here
