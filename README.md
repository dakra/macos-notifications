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
```

`:on-action` is called with `(ID KEY)`; KEY is `"default"` for a click on
the notification.  `:replaces-id` replaces the callback too, so pass
`:on-action` again.  `macos-notifications-close` removes a notification
from Notification Center.

`macos-notifications-show-buffer` returns an `:on-action` function that
shows a buffer, the current one by default: it selects the window already
showing it, else pops to it, and focuses that frame.

### ghostel

[ghostel](https://github.com/dakra/ghostel) runs
`ghostel-notification-functions` with `(TITLE BODY)` for OSC 9 / OSC 777
notifications (Claude Code emits them when it needs attention) and for its
own program-status changes, the terminal buffer current.  Replace the
default `alert` handler so a click jumps to that terminal:

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

## Limits

- No icon override, action buttons, dismiss callback or timeout: macOS
  offers no API for them on a plain notification.
- Clicks after Emacs quit are lost; the posting process is gone.
- `emacs -nw` and `--batch` signal a `user-error`; a daemon works once it
  has a GUI frame.
