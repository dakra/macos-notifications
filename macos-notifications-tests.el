;;; macos-notifications-tests.el --- Tests for macos-notifications.el -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT test suite.  Run with `make test'.  The click path itself needs a
;; human.

;;; Code:

(require 'ert)
(require 'macos-notifications)

(declare-function macos-notifications--notify "macos-notifications-module")
(declare-function macos-notifications--flush "macos-notifications-module")

(macos-notifications--ensure-module)

(defun macos-notifications-tests--run-timers ()
  "Run the pending callback timers."
  (dolist (timer (copy-sequence timer-list))
    (when (eq (timer--function timer) #'macos-notifications--run-callback)
      (timer-event-handler timer))))

(ert-deftest macos-notifications-tests-filter-dispatch ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending "")
        (calls nil))
    (puthash 12 (list 1 (lambda (id key) (push (list id key) calls)))
             macos-notifications--callbacks)
    (puthash 13 (list 2 (lambda (id key) (push (list id key) calls)))
             macos-notifications--callbacks)
    (macos-notifications--filter nil "12 1 def")
    (should (equal macos-notifications--pending "12 1 def"))
    (macos-notifications--filter nil "ault\n13 2 allow\n")
    (should (equal macos-notifications--pending ""))
    (macos-notifications-tests--run-timers)
    (should (equal (nreverse calls) '((12 "default") (13 "allow"))))
    (should (zerop (hash-table-count macos-notifications--callbacks)))))

(ert-deftest macos-notifications-tests-reply-and-dismiss ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending "")
        (calls nil))
    (dolist (id '(1 2 3))
      (puthash id (list id
                        (lambda (id key) (push (list 'action id key) calls))
                        (lambda (id text) (push (list 'reply id text) calls))
                        (lambda (id reason) (push (list 'close id reason) calls)))
               macos-notifications--callbacks))
    (macos-notifications--filter nil "1 1 reply aMOpIHg=\n2 2 dismiss\n3 3 reply \n")
    (macos-notifications-tests--run-timers)
    (should (equal (nreverse calls)
                   '((reply 1 "hé x") (close 2 dismissed) (reply 3 ""))))
    (should (zerop (hash-table-count macos-notifications--callbacks)))))

(ert-deftest macos-notifications-tests-bad-line-skipped ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending "")
        (debug-on-error t)
        (calls nil))
    (dolist (id '(1 2))
      (puthash id (list id
                        (lambda (id key) (push (list id key) calls))
                        (lambda (id text) (push (list id text) calls)))
               macos-notifications--callbacks))
    (macos-notifications--filter nil "1 1 reply (null)\n2 2 default\n")
    (macos-notifications-tests--run-timers)
    (should (equal calls '((2 "default"))))))

(ert-deftest macos-notifications-tests-stale-events ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending "")
        (calls nil))
    (puthash 1 (list 5
                     (lambda (id key) (push (list 'action id key) calls))
                     (lambda (id text) (push (list 'reply id text) calls))
                     (lambda (id reason) (push (list 'close id reason) calls)))
             macos-notifications--callbacks)
    (macos-notifications--filter
     nil "1 4 default\n1 4 reply eA==\n1 4 dismiss\ndenied 1 4\n")
    (macos-notifications-tests--run-timers)
    (should-not calls)
    (should (gethash 1 macos-notifications--callbacks))
    (macos-notifications--filter nil "1 5 allow\n")
    (macos-notifications-tests--run-timers)
    (should (equal calls '((action 1 "allow"))))
    (should-not (gethash 1 macos-notifications--callbacks))
    (macos-notifications--filter nil "2 1 default\n")
    (macos-notifications-tests--run-timers)
    (should (equal calls '((action 1 "allow"))))))

(ert-deftest macos-notifications-tests-notify-stores-serial ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--ids nil)
        (macos-notifications--counter 0)
        (macos-notifications--pending "")
        (serial 6)
        (calls nil))
    (cl-letf (((symbol-function 'window-system) (lambda (&optional _) 'ns))
              ((symbol-function 'macos-notifications--ensure-module) #'ignore)
              ((symbol-function 'macos-notifications--ensure-channel) #'ignore)
              ((symbol-function 'macos-notifications--notify)
               (lambda (&rest _) (cl-incf serial))))
      (let* ((callback (lambda (id key) (push (list id key) calls)))
             (id (macos-notifications-notify :title "t" :on-action callback)))
        (macos-notifications-notify :title "t" :replaces-id id :on-action callback)
        (macos-notifications--filter nil (format "%d 7 default\n" id))
        (macos-notifications-tests--run-timers)
        (should-not calls)
        (macos-notifications--filter nil (format "%d 8 default\n" id))
        (macos-notifications-tests--run-timers)
        (should (equal calls `((,id "default"))))))))

(ert-deftest macos-notifications-tests-check-actions ()
  (macos-notifications--check-actions nil)
  (macos-notifications--check-actions '("allow" "Allow" "deny" "Deny"))
  (dolist (bad '(("bad key" "Label") ("a\nb" "Label") ("default" "Label")
                 ("" "Label") (allow "Label") ("allow" label) ("allow")
                 ("allow" "A" "allow" "B") ["allow" "Label"]))
    (with-temp-buffer
      (emacs-lisp-mode)
      (should-error (macos-notifications--check-actions bad)))))

(ert-deftest macos-notifications-tests-module-argument-types ()
  (should-error (macos-notifications--notify 1 "t" "b" nil ["a" 1] nil nil nil nil)
                :type 'wrong-type-argument)
  (should-error (macos-notifications--notify 1 "t" "b" nil nil 1 nil nil nil)
                :type 'wrong-type-argument)
  (should-error (macos-notifications--notify "1" "t" "b" nil nil nil nil nil nil)
                :type 'wrong-type-argument))

(ert-deftest macos-notifications-tests-module-invalid-strings ()
  (let ((surrogate (string #xd83d)))
    (dolist (args `((,surrogate "b" nil nil nil nil nil nil)
                    ("t" ,surrogate nil nil nil nil nil nil)
                    ("t" "b" ,surrogate nil nil nil nil nil)
                    ("t" "b" nil ["key" ,surrogate] nil t nil nil)
                    ("t" "b" nil nil ,surrogate nil nil nil)
                    ("t" "b" nil nil nil nil nil ,surrogate)))
      (should (equal (should-error (apply #'macos-notifications--notify 1 args))
                     '(error "String is not valid UTF-8"))))))

(ert-deftest macos-notifications-tests-callback-error-reported ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending ""))
    (puthash 1 (list 1 (lambda (_id _key) (error "Boom")))
             macos-notifications--callbacks)
    (macos-notifications--filter nil "1 1 default\n")
    (macos-notifications-tests--run-timers)
    (with-current-buffer (messages-buffer)
      (should (string-match-p "callback error: Boom" (buffer-string))))))

(ert-deftest macos-notifications-tests-prune ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--ids nil))
    (dotimes (i 300)
      (let ((id (1+ i)))
        (macos-notifications--register id #'ignore)
        (when (zerop (% id 7))
          (remhash id macos-notifications--callbacks))))
    (macos-notifications--register 3 #'ignore)
    (let ((keys nil))
      (maphash (lambda (id _) (push id keys)) macos-notifications--callbacks)
      (should (equal (sort keys #'<)
                     (cons 3 (cl-remove-if (lambda (id) (zerop (% id 7)))
                                           (number-sequence 46 300))))))))

(ert-deftest macos-notifications-tests-finished-ids-free-their-slot ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--ids nil)
        (macos-notifications--pending ""))
    (cl-letf (((symbol-function 'macos-notifications--close) #'ignore))
      (macos-notifications--register 1 (list 1))
      (dotimes (i 300)
        (let ((id (+ 2 i)))
          (macos-notifications--register id (list 1))
          (if (zerop (% i 2))
              (macos-notifications--filter nil (format "%d 1 default\n" id))
            (macos-notifications-close id))))
      (macos-notifications--register 400 (list 1))
      (macos-notifications--filter nil "denied 400 1\n"))
    (should (gethash 1 macos-notifications--callbacks))
    (should (equal macos-notifications--ids '(1)))))

(ert-deftest macos-notifications-tests-channel-process ()
  (let ((macos-notifications--process nil)
        (opened nil))
    (cl-letf (((symbol-function 'macos-notifications--open)
               (lambda (process) (setq opened process))))
      (unwind-protect
          (progn
            (macos-notifications--ensure-channel)
            (should (eq opened macos-notifications--process))
            (should (memq #'macos-notifications--flush kill-emacs-hook))
            (should (process-live-p opened))
            (should-not (process-buffer opened))
            (should-not (get-buffer " *macos-notifications*"))
            (should (equal (process-coding-system opened)
                           '(utf-8-unix . utf-8-unix))))
        (when opened (delete-process opened))))))

(ert-deftest macos-notifications-tests-stale-module ()
  (let* ((macos-notifications--dir (file-name-as-directory
                                    (make-temp-file "macos-notifications" t)))
         (module (expand-file-name (concat "macos-notifications-module"
                                           module-file-suffix)
                                   macos-notifications--dir))
         (source (expand-file-name "macos-notifications-module.m"
                                   macos-notifications--dir)))
    (unwind-protect
        (progn
          (should (string-match-p
                   "not compiled"
                   (cadr (should-error (macos-notifications--check-module)
                                       :type 'user-error))))
          (write-region "" nil module nil 'silent)
          (write-region "" nil source nil 'silent)
          (set-file-times module (time-subtract nil 60))
          (should (string-match-p
                   "older than its source"
                   (cadr (should-error (macos-notifications--check-module)
                                       :type 'user-error))))
          (set-file-times source (time-subtract nil 120))
          (macos-notifications--check-module))
      (delete-directory macos-notifications--dir t))))

(ert-deftest macos-notifications-tests-post-errors ()
  (let ((macos-notifications--callbacks (make-hash-table))
        (macos-notifications--pending ""))
    (dolist (id '(1 2 3))
      (puthash id (list 1 #'ignore) macos-notifications--callbacks))
    (let ((start (with-current-buffer (messages-buffer) (point-max))))
      (macos-notifications--filter nil "error 2 1 YmFkIGltYWdl\ndenied 1 1\n")
      (with-current-buffer (messages-buffer)
        (let ((logged (buffer-substring start (point-max))))
          (should (string-match-p "System Settings" logged))
          (should (string-match-p "post error: bad image" logged)))))
    (should-not (gethash 1 macos-notifications--callbacks))
    (should (gethash 2 macos-notifications--callbacks))
    (should (gethash 3 macos-notifications--callbacks))))

(ert-deftest macos-notifications-tests-show-buffer ()
  (let ((buf (generate-new-buffer "show"))
        (focused nil)
        (pops 0))
    (cl-letf (((symbol-function 'select-frame-set-input-focus)
               (lambda (frame) (setq focused frame))))
      (advice-add 'pop-to-buffer :before (lambda (&rest _) (cl-incf pops))
                  '((name . macos-notifications-tests)))
      (unwind-protect
          (progn
            (funcall (macos-notifications-show-buffer buf) 1 "default")
            (should (= pops 1))
            (should (eq focused (selected-frame)))
            (should (eq (window-buffer) buf))
            (select-window (next-window))
            (should-not (eq (window-buffer) buf))
            (setq focused nil)
            (funcall (macos-notifications-show-buffer buf) 1 "default")
            (should (= pops 1))
            (should (eq focused (selected-frame)))
            (should (eq (window-buffer) buf))
            (kill-buffer buf)
            (setq focused nil)
            (funcall (macos-notifications-show-buffer buf) 1 "default")
            (should-not focused))
        (advice-remove 'pop-to-buffer 'macos-notifications-tests)
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest macos-notifications-tests-module-loaded ()
  (should (fboundp 'macos-notifications--open)))

(ert-deftest macos-notifications-tests-gui-gate ()
  (should-error (macos-notifications-notify :title "t" :body "b")
                :type 'user-error))

(provide 'macos-notifications-tests)
;;; macos-notifications-tests.el ends here
