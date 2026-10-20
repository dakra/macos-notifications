;;; macos-notifications.el --- Native macOS notifications with click callbacks -*- lexical-binding: t -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/macos-notifications
;; Keywords: notifications, tools
;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Posts macOS notifications from inside the Emacs process through a
;; dynamic module and delivers clicks on them back to Lisp.  The API
;; mirrors `notifications-notify' where macOS allows.
;;
;; Requires a GUI Emacs.app (NS build) running from an app bundle that
;; LaunchServices knows about.

;;; Code:

(require 'cl-lib)

(unless (eq system-type 'darwin)
  (user-error "The macos-notifications package only works on macOS"))

(unless module-file-suffix
  (error "Module support not detected, macos-notifications can't work"))

(defconst macos-notifications--dir
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "macos-notifications")))
  "Directory containing the macos-notifications dynamic module source.")

(defun macos-notifications-module-compile ()
  "Compile the macos-notifications dynamic module."
  (interactive)
  (let ((default-directory macos-notifications--dir)
        (buffer (get-buffer-create "*macos-notifications-module-compile*")))
    (message "Compiling the macos-notifications dynamic module...")
    (if (zerop (call-process "make" nil buffer t
                             (concat "macos-notifications-module" module-file-suffix)))
        (message "Compiling the macos-notifications dynamic module...done")
      (pop-to-buffer buffer)
      (error "Compilation of the macos-notifications dynamic module failed"))))

(unless (require 'macos-notifications-module nil t)
  (if (or noninteractive
          (y-or-n-p "The macos-notifications dynamic module is not compiled.  Compile it now? "))
      (progn
        (macos-notifications-module-compile)
        (require 'macos-notifications-module))
    (error "The macos-notifications module is not compiled; run `make' in %s"
           macos-notifications--dir)))

(declare-function macos-notifications--open "macos-notifications-module")
(declare-function macos-notifications--notify "macos-notifications-module")
(declare-function macos-notifications--close "macos-notifications-module")

(defvar macos-notifications--counter 0
  "Last notification id handed out.")

(defvar macos-notifications--callbacks (make-hash-table)
  "Notification id -> `:on-action' function.")

(defvar macos-notifications--process nil
  "Pipe process the module writes notification events to.")

(defvar macos-notifications--pending ""
  "Partial line received from the module, waiting for its newline.")

(defun macos-notifications--run-callback (fn id key)
  "Call FN with ID and KEY, reporting instead of propagating errors."
  (condition-case err
      (funcall fn id key)
    (error (message "macos-notifications callback error: %s"
                    (error-message-string err)))))

(defun macos-notifications--dispatch (line)
  "Handle one event LINE from the module."
  (pcase (split-string line " ")
    ('("auth" "denied")
     (message "Notifications for Emacs are disabled; allow Emacs in \
System Settings > Notifications"))
    (`("auth" ,_))
    (`(,id ,key)
     (let* ((id (string-to-number id))
            (fn (gethash id macos-notifications--callbacks)))
       (remhash id macos-notifications--callbacks)
       (when fn
         (run-at-time 0 nil #'macos-notifications--run-callback fn id key))))))

(defun macos-notifications--filter (_process output)
  "Split OUTPUT into lines and dispatch each complete one."
  (let ((lines (split-string (concat macos-notifications--pending output) "\n")))
    (setq macos-notifications--pending (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (macos-notifications--dispatch line)))))

(defun macos-notifications--ensure-channel ()
  "Create the pipe process and hand it to the module unless it is alive."
  (unless (process-live-p macos-notifications--process)
    (let ((process (make-pipe-process :name "macos-notifications" :noquery t
                                      :filter #'macos-notifications--filter)))
      (condition-case err
          (macos-notifications--open process)
        (error (delete-process process)
               (signal (car err) (cdr err))))
      (setq macos-notifications--pending ""
            macos-notifications--process process))))

(defun macos-notifications--prune ()
  "Drop callbacks older than the newest 256 ids."
  (let ((floor (- macos-notifications--counter 255)))
    (maphash (lambda (id _)
               (when (< id floor)
                 (remhash id macos-notifications--callbacks)))
             macos-notifications--callbacks)))

;;;###autoload
(cl-defun macos-notifications-notify (&key title body sound replaces-id on-action)
  "Post a macOS notification and return its integer id.
TITLE and BODY are strings.  SOUND non-nil plays the default sound.
REPLACES-ID replaces the notification with that id, including its
ON-ACTION.  ON-ACTION is called with (ID KEY) when the notification
is clicked; KEY is \"default\" for a click on the notification body."
  (unless (eq (window-system) 'ns)
    (user-error "Notifications need a GUI Emacs.app frame"))
  (macos-notifications--ensure-channel)
  (let ((id (or replaces-id (cl-incf macos-notifications--counter))))
    (macos-notifications--prune)
    (if on-action
        (puthash id on-action macos-notifications--callbacks)
      (remhash id macos-notifications--callbacks))
    (macos-notifications--notify id (or title "") (or body "") sound)
    id))

(defun macos-notifications-close (id)
  "Remove notification ID from Notification Center."
  (remhash id macos-notifications--callbacks)
  (macos-notifications--close id))

(provide 'macos-notifications)
;;; macos-notifications.el ends here
