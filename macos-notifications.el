;;; macos-notifications.el --- Native macOS notifications with click callbacks -*- lexical-binding: t -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; Assisted-by: Claude:claude-fable-5-1
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

(defconst macos-notifications--dir
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "macos-notifications")))
  "Directory containing the macos-notifications dynamic module source.")

;;;###autoload
(defun macos-notifications-module-compile ()
  "Compile the macos-notifications dynamic module with `make'.
A module already loaded into this Emacs stays in use until restart."
  (interactive)
  (let ((default-directory macos-notifications--dir)
        (buffer (get-buffer-create "*macos-notifications-module-compile*")))
    (message "Compiling the macos-notifications dynamic module...")
    (if (zerop (call-process "make" nil buffer t
                             (concat "macos-notifications-module" module-file-suffix)))
        (message "Compiling the macos-notifications dynamic module...done%s"
                 (if (featurep 'macos-notifications-module)
                     "; restart Emacs to load it" ""))
      (pop-to-buffer buffer)
      (error "Compilation of the macos-notifications dynamic module failed"))))

(defun macos-notifications--check-module ()
  "Signal a `user-error' when the module is not compiled or older than its source."
  (let ((module (expand-file-name
                 (concat "macos-notifications-module" module-file-suffix)
                 macos-notifications--dir))
        (source (expand-file-name "macos-notifications-module.m"
                                  macos-notifications--dir)))
    (unless (file-exists-p module)
      (user-error "The macos-notifications module is not compiled; \
run M-x macos-notifications-module-compile"))
    (when (file-newer-than-file-p source module)
      (user-error "The macos-notifications module is older than its source; \
run M-x macos-notifications-module-compile"))))

(defun macos-notifications--ensure-module ()
  "Load the dynamic module, signaling a `user-error' when it is not usable."
  (unless (featurep 'macos-notifications-module)
    (unless module-file-suffix
      (error "This Emacs has no dynamic module support"))
    (macos-notifications--check-module)
    (let ((load-path (cons macos-notifications--dir load-path)))
      (require 'macos-notifications-module))))

(declare-function macos-notifications--open "macos-notifications-module")
(declare-function macos-notifications--notify "macos-notifications-module")
(declare-function macos-notifications--close "macos-notifications-module")
(declare-function macos-notifications--flush "macos-notifications-module")

(defvar macos-notifications--counter 0
  "Last notification id handed out.")

(defvar macos-notifications--callbacks (make-hash-table)
  "Notification id -> list of post serial, `:on-action', `:on-reply', `:on-close'.")

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

(defun macos-notifications--unregister (id)
  "Forget the callbacks of notification ID."
  (remhash id macos-notifications--callbacks)
  (setq macos-notifications--ids (delete id macos-notifications--ids)))

(defun macos-notifications--decode (field)
  "Return the text of FIELD, a line field the module encoded."
  (decode-coding-string (base64-decode-string field) 'utf-8))

(defun macos-notifications--current-p (id serial)
  "Return non-nil if the callbacks of ID belong to the post with SERIAL.
SERIAL is a field of an event line."
  (eql (string-to-number serial)
       (car (gethash id macos-notifications--callbacks))))

(defun macos-notifications--dispatch (line)
  "Handle one event LINE from the module.
An event of a post that was replaced leaves the callbacks alone."
  (pcase (split-string line " ")
    (`("denied" ,id ,serial)
     (let ((id (string-to-number id)))
       (when (macos-notifications--current-p id serial)
         (macos-notifications--unregister id)))
     (message "Notifications for Emacs are not allowed; allow them in \
the permission prompt or in System Settings > Notifications"))
    ;; The callbacks stay: the notification may be delivered all the
    ;; same, for instance without its image.
    (`("error" ,_id ,_serial ,description)
     (message "macos-notifications post error: %s"
              (macos-notifications--decode description)))
    (`(,id ,serial ,key . ,rest)
     (let ((id (string-to-number id)))
       (when (macos-notifications--current-p id serial)
         (pcase-let ((`(,_ ,on-action ,on-reply ,on-close)
                      (gethash id macos-notifications--callbacks)))
           (macos-notifications--unregister id)
           (pcase key
             ("reply"
              (macos-notifications--schedule
               on-reply id (macos-notifications--decode (or (car rest) ""))))
             ("dismiss" (macos-notifications--schedule on-close id 'dismissed))
             (_ (macos-notifications--schedule on-action id key)))))))))

(defun macos-notifications--filter (_process output)
  "Split OUTPUT into lines and dispatch each complete one."
  (let ((lines (split-string (concat macos-notifications--pending output) "\n")))
    (setq macos-notifications--pending (car (last lines)))
    (dolist (line (butlast lines))
      (unless (equal line "")
        (condition-case err
            (macos-notifications--dispatch line)
          (error (message "macos-notifications event error: %S" err)))))))

(defun macos-notifications--ensure-channel ()
  "Create the pipe process and hand it to the module unless it is alive."
  (unless (process-live-p macos-notifications--process)
    (let ((process
           ;; Before Emacs 31 a pipe process cannot be created without
           ;; a buffer.
           (let ((buffer (generate-new-buffer " *macos-notifications*" t)))
             (unwind-protect
                 (let ((process (make-pipe-process
                                 :name "macos-notifications" :buffer buffer
                                 :coding 'utf-8-unix :noquery t
                                 :filter #'macos-notifications--filter)))
                   (set-process-buffer process nil)
                   process)
               (kill-buffer buffer)))))
      (condition-case err
          (macos-notifications--open process)
        (error (delete-process process)
               (signal (car err) (cdr err))))
      ;; Late, for a notification posted from `kill-emacs-hook'.
      (add-hook 'kill-emacs-hook #'macos-notifications--flush 90)
      (setq macos-notifications--pending ""
            macos-notifications--process process))))

(defun macos-notifications--register (id callbacks)
  "Store CALLBACKS for ID, keeping only the newest 256 ids."
  (puthash id callbacks macos-notifications--callbacks)
  (setq macos-notifications--ids (cons id (delete id macos-notifications--ids)))
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
  (macos-notifications--ensure-module)
  (macos-notifications--ensure-channel)
  (let* ((id (or replaces-id (cl-incf macos-notifications--counter)))
         (serial (macos-notifications--notify
                  id (or title "") (or body "") sound
                  (and actions (vconcat actions)) reply
                  (and on-close t) (eq urgency 'low)
                  (and image-path (expand-file-name image-path)))))
    (setq macos-notifications--counter (max macos-notifications--counter id))
    (if (or on-action on-reply on-close)
        (macos-notifications--register id (list serial on-action on-reply on-close))
      (macos-notifications--unregister id))
    id))

(defun macos-notifications-close (id)
  "Remove notification ID from Notification Center."
  (macos-notifications--unregister id)
  (when (featurep 'macos-notifications-module)
    (macos-notifications--close id)))

;;;###autoload
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
