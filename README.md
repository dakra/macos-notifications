# macos-notifications

Native macOS notifications from Emacs, with clicks delivered back to
Emacs Lisp.  The macOS counterpart of `notifications.el`.

macOS hands a notification click only to the process that posted it, and
only if that process installed a notification-center delegate.  Emacs's NS
port installs none, so `display notification` via AppleScript can at best
activate Emacs, and external posters like terminal-notifier show their own
icon and route the click through emacsclient.  This package loads a small
dynamic module into Emacs.app that posts through `UNUserNotificationCenter`
and installs the delegate in-process: Emacs icon, Emacs's existing
notification permission, click lands in Lisp.

## Requirements

- Emacs 28.1+ with dynamic module support, GUI NS build running from
  Emacs.app (a bundle LaunchServices knows about).
- Xcode command line tools (`clang`) to build the module.

## Install

```elisp
(package-vc-install "https://github.com/dakra/macos-notifications")
```

The first `(require 'macos-notifications)` offers to compile the module;
`make` in the package directory does the same.

## Usage

```elisp
(macos-notifications-notify
 :title "Build finished"
 :body "All tests passed"
 :sound t
 :on-action (lambda (id key) (message "notification %d clicked (%s)" id key)))
;; => 1

(macos-notifications-notify :title "Still running" :replaces-id 1)
(macos-notifications-close 1)

(macos-notifications-notify
 :title "Claude Code" :body "Permission: run `make test`?"
 :actions '("allow" "Allow" "deny" "Deny")
 :reply "Tell Claude..."
 :sound "Glass"
 :image-path "~/Pictures/claude.png"
 :on-action (lambda (_id key) (message "button %s" key))
 :on-reply (lambda (_id text) (message "reply: %s" text))
 :on-close (lambda (_id reason) (message "closed: %s" reason)))
```

All keywords:

|Keyword          |Value                                                                                     |
|-----------------|------------------------------------------------------------------------------------------|
|`:title`, `:body`|strings                                                                                   |
|`:sound`         |`t` for the default sound, or a name from the Library/Sounds directories such as `"Glass"`|
|`:urgency`       |`low` delivers quietly to the notification list, without a banner                         |
|`:image-path`    |local image file shown in the notification                                                |
|`:actions`       |flat list of `KEY LABEL` strings shown as buttons; more than two collapse into a menu     |
|`:reply`         |placeholder string; adds a text field                                                     |
|`:replaces-id`   |id of a notification to replace, callbacks included                                       |
|`:on-action`     |called with `(ID KEY)`; KEY is `"default"` for a click on the body, else the button's key |
|`:on-reply`      |called with `(ID TEXT)`                                                                   |
|`:on-close`      |called with `(ID 'dismissed)` when the user dismisses the notification explicitly         |

A click on the body activates Emacs; a button or reply does not.  Keys
must be non-empty, contain no whitespace and not be `default`, `reply`
or `dismiss`.  `macos-notifications-close` removes a notification from
Notification Center.

`macos-notifications-show-buffer` returns an `:on-action` function that
shows a buffer, the current one by default: it selects the window already
showing it, else pops to it, and focuses that frame.

### ghostel

[ghostel](https://github.com/dakra/ghostel) runs
`ghostel-notification-functions` with `(TITLE BODY)` for OSC 9 / OSC 777
notifications and, through `ghostel-status-notify`, for program-status
changes (OSC 7501, which Claude Code speaks), the terminal buffer current.
Replace the default `alert` handler so a click jumps to that terminal:

```elisp
(defun my-ghostel-notify (title body)
  (macos-notifications-notify
   :title (if (string-empty-p title) (buffer-name) title)
   :body body
   :on-action (macos-notifications-show-buffer)))

(with-eval-after-load 'ghostel-status
  (remove-hook 'ghostel-notification-functions #'ghostel-default-notify)
  (add-hook 'ghostel-notification-functions #'my-ghostel-notify))
```

or simply, when nothing else needs to stay on the hook:

```elisp
(setq ghostel-notification-functions '(my-ghostel-notify))
```

Program-status changes (OSC 7501) carry more than a title and a body:
`ghostel-program-status-functions` runs with `(ID OLD NEW)`, NEW a plist
with `:state`, `:kind`, `:msg` and more, ID `""` for the program itself
and anything else for a child such as a Claude Code subagent.  A member
there can answer a permission prompt from the banner, keep one banner
per record, update it when a later report in the same state adds a
message (Claude Code sends `done` first and a summary a moment later)
and close it when the state changes or the record goes.  The keys are
Claude Code's: Enter accepts the highlighted option, Esc declines and
returns to the input.

```elisp
(defvar-local my-ghostel-status-notifications nil
  "Alist of (RECORD-ID . NOTIFICATION-ID).")

(defun my-ghostel-status-notify (id old new)
  (let* ((root (equal id ""))
         (state (plist-get new :state))
         (nid (alist-get id my-ghostel-status-notifications nil nil #'equal))
         (same (and nid (eq state (plist-get old :state)))))
    (when (and nid (not same))
      (macos-notifications-close nid)
      (setf (alist-get id my-ghostel-status-notifications nil t #'equal) nil))
    ;; Any record blocked or in error notifies, done only the root.
    (when (or same
              (and (ghostel-status-attention-p old new)
                   (or root (memq state '(blocked error)))))
      (let ((buf (current-buffer))
            (show (macos-notifications-show-buffer))
            (permission (and root (eq (plist-get new :kind) 'permission))))
        (setf (alist-get id my-ghostel-status-notifications nil nil #'equal)
              (macos-notifications-notify
               :replaces-id (and same nid)
               :title (or (plist-get new :title) (ghostel-status-app id)
                          (buffer-name))
               :body (or (plist-get new :msg) (symbol-name state))
               :actions (and permission '("allow" "Allow" "deny" "Deny"))
               :reply (and root "Tell Claude…")
               :on-action (lambda (nid key)
                            (with-current-buffer buf
                              (pcase key
                                ("allow" (ghostel-send-key "return"))
                                ("deny" (ghostel-send-key "escape"))
                                (_ (funcall show nid key)))))
               :on-reply (lambda (_nid text)
                           (with-current-buffer buf
                             (when permission (ghostel-send-key "escape"))
                             (ghostel-send-string text)
                             (ghostel-send-key "return")))))))))

(with-eval-after-load 'ghostel-status
  (remove-hook 'ghostel-program-status-functions #'ghostel-status-notify)
  (add-hook 'ghostel-program-status-functions #'my-ghostel-status-notify))
```

## Limits

- The icon is always the Emacs icon; macOS has no API to change it per
  notification.
- No timeout: how long a banner stays is the user's System Settings
  choice.  Call `macos-notifications-close` from a timer if needed.
- `:on-close` fires only for an explicit dismissal; a banner that slides
  away into the notification list is not one.
- A notification outlives the Emacs session that posted it, but a click
  on it then does nothing; the callback is gone.
- With several Emacs.app instances running, macOS delivers every click to
  one of them, not necessarily the one that posted the notification.
  Each instance registers its own button sets, replacing the others'; they
  are re-registered with every notification, so a banner posted after
  another instance's keeps its buttons.
- `emacs -nw` and `--batch` signal a `user-error`; a daemon works once it
  has a GUI frame.
