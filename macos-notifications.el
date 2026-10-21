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
(require 'url-util)

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
  "Notification id -> list of `:on-action', `:on-reply' and `:on-close'.")

(defvar macos-notifications--ids nil
  "Ids with registered callbacks, newest first.")

(defvar macos-notifications--process nil
  "Pipe process the module writes notification events to.")

(defvar macos-notifications--pending ""
  "Partial line received from the module, waiting for its newline.")

(defun macos-notifications--run-callback (fn &rest args)
  "Apply FN to ARGS, reporting instead of propagating errors."
  (condition-case err
      (apply fn args)
    (error (message "macos-notifications callback error: %s"
                    (error-message-string err)))))

(defun macos-notifications--schedule (fn &rest args)
  "Apply FN to ARGS from a timer, unless FN is nil."
  (when fn
    (apply #'run-at-time 0 nil #'macos-notifications--run-callback fn args)))

(defun macos-notifications--dispatch (line)
  "Handle one event LINE from the module."
  (pcase (split-string line " ")
    ('("auth" "denied")
     (message "Notifications for Emacs are disabled; allow Emacs in \
System Settings > Notifications"))
    (`("auth" ,_))
    (`(,id ,key . ,rest)
     (let ((id (string-to-number id)))
       (pcase-let ((`(,on-action ,on-reply ,on-close)
                    (gethash id macos-notifications--callbacks)))
         (remhash id macos-notifications--callbacks)
         (pcase key
           ("reply"
            (macos-notifications--schedule
             on-reply id
             (decode-coding-string (url-unhex-string (or (car rest) "") t) 'utf-8)))
           ("dismiss" (macos-notifications--schedule on-close id 'dismissed))
           (_ (macos-notifications--schedule on-action id key))))))))

(defun macos-notifications--filter (_process output)
  "Split OUTPUT into lines and dispatch each complete one."
  (let ((lines (split-string (concat macos-notifications--pending output) "\n")))
    (setq macos-notifications--pending (car (last lines)))
    (dolist (line (butlast lines))
      (unless (equal line "")
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

(defun macos-notifications--register (id callbacks)
  "Store CALLBACKS for ID, keeping only the newest 256 ids."
  (puthash id callbacks macos-notifications--callbacks)
  (setq macos-notifications--ids (cons id (delq id macos-notifications--ids)))
  (let ((tail (nthcdr 255 macos-notifications--ids)))
    (dolist (old (cdr tail))
      (remhash old macos-notifications--callbacks))
    (when tail
      (setcdr tail nil))))

(defun macos-notifications--check-actions (actions)
  "Signal an error unless ACTIONS is a list of usable KEY LABEL pairs."
  (unless (listp actions)
    (error "Actions must be a list, not %S" actions))
  (let (keys)
    (cl-loop for (key label) on actions by #'cddr
             unless (and (stringp key) (stringp label)
                         (not (equal key ""))
                         (not (member key '("default" "reply" "dismiss")))
                         (not (member key keys))
                         (not (string-match-p "[ \t\n\r]" key)))
             do (error "Invalid action: %S %S" key label)
             do (push key keys))))

;;;###autoload
(cl-defun macos-notifications-notify (&key title body sound urgency image-path
                                           actions reply replaces-id
                                           on-action on-reply on-close)
  "Post a macOS notification and return its integer id.
TITLE and BODY are strings.  SOUND t plays the default sound,
a string the system or user sound of that name.
URGENCY `low' delivers quietly to the notification list.
IMAGE-PATH is a local image file shown in the notification.
ACTIONS is a flat list of KEY LABEL strings shown as buttons.
REPLY, a placeholder string, adds a text field.
REPLACES-ID replaces the notification with that id and its callbacks.
ON-ACTION is called with (ID KEY), KEY being the button's key or
\"default\" for a click on the body.
ON-REPLY with (ID TEXT) for an entered reply; ON-CLOSE with
\(ID \\='dismissed) when the user dismisses the notification."
  (macos-notifications--check-actions actions)
  (unless (cl-some (lambda (f) (eq (window-system f) 'ns)) (frame-list))
    (user-error "Notifications need a GUI Emacs.app frame"))
  (macos-notifications--ensure-channel)
  (let ((id (or replaces-id (cl-incf macos-notifications--counter))))
    (macos-notifications--notify id (or title "") (or body "") sound
                                 (and actions (vconcat actions)) reply
                                 (and on-close t) (eq urgency 'low)
                                 (and image-path (expand-file-name image-path)))
    (setq macos-notifications--counter (max macos-notifications--counter id))
    (if (or on-action on-reply on-close)
        (macos-notifications--register id (list on-action on-reply on-close))
      (remhash id macos-notifications--callbacks))
    id))

(defun macos-notifications-close (id)
  "Remove notification ID from Notification Center."
  (remhash id macos-notifications--callbacks)
  (macos-notifications--close id))

(defun macos-notifications-show-buffer (&optional buffer)
  "Return an `:on-action' function that shows BUFFER, default the current one.
Selects the window already showing BUFFER, else pops to it, and
focuses that frame."
  (let ((buf (or buffer (current-buffer))))
    (lambda (_id _key)
      (when (buffer-live-p buf)
        (let ((win (get-buffer-window buf t)))
          (if win (select-window win) (pop-to-buffer buf)))
        (select-frame-set-input-focus (selected-frame))))))

(provide 'macos-notifications)
;;; macos-notifications.el ends here
