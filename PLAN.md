# macos-notifications: plan

Emacs package that posts native macOS notifications from inside the Emacs
process and delivers notification clicks back to Emacs Lisp.  It is the
macOS counterpart of Emacs's own `notifications.el` (D-Bus / libnotify) and
mirrors its API where the platform allows.

Repo: `~/src/dakra/macos-notifications` (GitHub: dakra/macos-notifications).
Nothing exists yet besides this file.

## Why this package exists

macOS delivers a notification click only to the process that posted the
notification, and only if that process registered a notification-center
delegate.  Nothing else can observe the click.

- `display notification` via `do-applescript` posts as Emacs but installs no
  delegate: a click can only activate Emacs.  Emacs's NS port
  (`src/nsterm.m`, `src/nsfns.m`) does not touch UNUserNotificationCenter or
  NSUserNotificationCenter at all, verified against the Emacs source tree.
- `osascript` from a shell posts as Script Editor.
- A bare Swift/Python binary cannot use the UserNotifications framework; the
  poster must be an app bundle with a bundle identifier (the framework
  throws `bundleProxyForCurrentProcess is nil` otherwise).
- terminal-notifier is a minimal app bundle doing exactly this, but the
  notification then shows the terminal-notifier icon, needs its own
  permission grant, and the click comes back through `-execute`
  + emacsclient.

A dynamic module loaded into Emacs.app registers the delegate in-process:
Emacs icon, Emacs's existing notification permission, click lands in Lisp.

Prior art checked (2026-10-20): nothing on MELPA, nothing on GitHub (repo and
code search for `emacs_module_init` + UNUserNotificationCenter /
NSUserNotification).  Closest: xenodium's EmacsMacOSModule (Swift modules
for share sheet / reveal in Finder, no notifications) built on
SavchenkoValeriy/emacs-swift-module.

## Design decisions (settled)

- **Language: Objective-C, raw `emacs-module.h` API.**  The whole module is
  Apple framework calls.  Zig would need hand-written ObjC runtime calls and
  translate-c fights with Apple headers.  Swift via emacs-swift-module adds a
  SwiftPM dependency and toolchain pull for ~150 lines of code.  clang ships
  with the Xcode CLT, which every Mac Emacs user building modules has.
- **UNUserNotificationCenter (UserNotifications.framework)**, not the
  deprecated NSUserNotificationCenter.
- **Click delivery via `open_channel`** (module API, Emacs 28+): the module
  gets a write fd for a Lisp `make-pipe-process`; the delegate callback
  writes one line to it from whatever thread it runs on; the process filter
  dispatches in Lisp.  This is the documented thread-safe way to push an
  asynchronous event from a module into Lisp (lispref "Module Misc",
  `open_channel`: "you can use the returned file descriptor from arbitrary
  threads, even if no module environment is active").
- **API mirrors `notifications-notify`**: keyword args, returns an integer
  id, `:on-action` called with `(ID KEY)`.
- **Minimum Emacs 28.1** (`open_channel`), **macOS 11+**
  (`UNNotificationPresentationOptionBanner`).  GUI NS build running from
  an app bundle that LaunchServices knows; the package signals a clear
  `user-error` otherwise.
- **Scope**: title, body, click callback, replace, close.  No custom action
  buttons, no `:on-close`, no icons (macOS offers no API to override a
  notification's icon), no sounds beyond a boolean.  See "Out of scope".

## Repo layout

Mirror `~/src/dakra/sodium.el` (same author, same conventions): flat repo,
one `.el`, one module source, vendored `emacs-module.h`, Makefile with
compile-on-first-load.

```
macos-notifications/
  macos-notifications.el          ; Lisp API + channel dispatch + module loader
  macos-notifications-module.m    ; Objective-C dynamic module
  emacs-module.h                  ; vendored from Emacs (GPL, same as sodium.el)
  Makefile
  macos-notifications-tests.el    ; ERT
  README.md
  LICENSE                         ; GPL-3.0-or-later
  .github/workflows/ci.yml
  PLAN.md                         ; this file; delete or move to docs/ once done
```

`emacs-module.h` source: `/opt/homebrew/Cellar/emacs-plus@32/32.0.50/include/emacs-module.h`
(copy it; `~/src/emacs/src/emacs-module.h.in` does not exist in that checkout,
the generated header lives in the install prefix).

## Module: `macos-notifications-module.m`

Exported `plugin_is_GPL_compatible`.  `emacs_module_init` defines these
Lisp functions (all prefixed `macos-notifications--`, private; the public
API is Lisp) and `provide`s `macos-notifications-module`:

| Lisp function | Args | Does |
|---|---|---|
| `macos-notifications--open` | `PROCESS` | `env->open_channel`; `close(2)` any previously stored fd and store the new one (the fd is a private `dup` of the pipe's write end, see `open_channel_for_module` in `src/process.c`, so a replaced pipe process means a new fd).  First call only: obtain `[UNUserNotificationCenter currentNotificationCenter]` inside `@try/@catch`, create and install the delegate object, call `requestAuthorizationWithOptions:(Alert\|Sound)`.  The framework raises `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") when LaunchServices has no bundle proxy for the process; an uncaught ObjC exception terminates Emacs, so the `@catch` turns it into a Lisp `error` and leaves the module unconfigured.  A non-nil `[NSBundle mainBundle].bundleIdentifier` is *not* a sufficient pre-check (unregistered or stale-registered bundles pass it). |
| `macos-notifications--notify` | `ID TITLE BODY SOUND` | Build `UNMutableNotificationContent` (title, body, `UNNotificationSound.defaultSound` when SOUND non-nil), `UNNotificationRequest` with identifier = decimal string of ID, no trigger, `addNotificationRequest:withCompletionHandler:`.  A non-nil `error` in the completion handler writes `"auth denied\n"` to the channel (same line as below), since a permission revoked after the first grant surfaces only there.  Posting the same identifier again replaces the earlier notification (this is how `:replaces-id` works). |
| `macos-notifications--close` | `ID` | `removePendingNotificationRequestsWithIdentifiers:` + `removeDeliveredNotificationsWithIdentifiers:`. |

Delegate (a tiny `NSObject <UNUserNotificationCenterDelegate>` kept in a
static so ARC never frees it):

- `userNotificationCenter:willPresentNotification:withCompletionHandler:`
  returns `Banner | List | Sound` (all macOS 11+, hence the floor).
  Without this macOS suppresses notifications posted by the frontmost
  app, i.e. nothing would show while the user is in Emacs looking at
  another buffer.
- `userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:`
  writes `"<identifier> <actionIdentifier>\n"` to the channel fd with
  `write(2)`, then calls the completion handler.  Body click arrives as
  `UNNotificationDefaultActionIdentifier` (the string
  `com.apple.UNNotificationDefaultActionIdentifier`); the module maps it to
  the word `default` before writing, so Lisp never sees Apple identifiers.
- The authorization completion handler writes `"auth granted\n"` or
  `"auth denied\n"` to the channel so Lisp can `message` a denial (the only
  way to tell the user why nothing shows up).  Nothing else may call
  `emacs_env` from these callbacks.

String conversion: `copy_string_contents` into a malloc'd buffer →
`[NSString stringWithUTF8String:]`.  Integers via `extract_integer`.
Errors (nil fd, caught ObjC exception) signal through
`non_local_exit_signal`.

Build (Makefile, single rule):

```
clang -ObjC -fobjc-arc -Wall -Wextra -O2 -dynamiclib \
  -mmacosx-version-min=11.0 \
  -framework Foundation -framework UserNotifications \
  -I. macos-notifications-module.m -o macos-notifications-module.dylib
```

`module-file-suffix` is `.dylib` on the NS build (verified).  Keep sodium's
Makefile shape (`EMACS`, `MODULE_SUFFIX` detection, `all`, `test`, `lint`,
`clean`) minus the Linux/Windows targets; this package is macOS only.

## Lisp: `macos-notifications.el`

Header: `Package-Requires: ((emacs "28.1"))`, GPL-3+, URL
https://github.com/dakra/macos-notifications, keywords `notifications`.

Loader: sodium's pattern verbatim (`macos-notifications--dir`,
`macos-notifications-module-compile`, `require` the module or offer to
`make` on first load).  Before requiring the module, refuse early with a
`user-error` unless `(eq system-type 'darwin)` (Linux and Windows fail
here with a readable message instead of a dlopen error).  `(featurep 'ns)`
is useless as a gate: `syms_of_nsterm` provides it unconditionally, so it
is `t` in `emacs -nw` and `--batch` of an NS build too (verified).  The
GUI check happens per call instead: `macos-notifications-notify` signals a
`user-error` unless `(eq (window-system) 'ns)` on the selected frame.
This is frame-based, so a daemon works once it has a GUI frame, and a
TTY Emacs never installs a delegate into a process without an
NSApplication run loop (where posting may work but clicks never arrive).

Public API:

```elisp
(macos-notifications-notify &rest PARAMS)
  ;; :title STRING   :body STRING   :sound BOOL
  ;; :replaces-id ID :on-action (lambda (id key) ...)
  ;; => ID (integer)
(macos-notifications-close ID)
```

- Ids come from an incrementing counter (`:replaces-id` reuses the given
  one).  Callbacks live in a hash table id → function.
- Every call runs `macos-notifications--ensure-channel`: unless the
  stored pipe process is `process-live-p` (the user can kill it from
  `list-processes`), create `(make-pipe-process :name "macos-notifications"
  :noquery t :filter #'macos-notifications--filter)` and hand it to
  `macos-notifications--open`, which replaces the module's fd.  The
  `@catch` error from `--open` propagates as-is; its message names the
  bundle problem.
- Filter: keep the pending partial line in a plain `defvar` (one channel
  per Emacs; the pipe has no buffer, so nothing is buffer-local), split on
  newline, for each `"<id> <key>"` line pop the callback from the table
  and schedule it with `(run-at-time 0 nil ...)`.  Callbacks must not run
  inside the filter: that is under `inhibit-quit` and may be nested in
  someone else's `accept-process-output` loop, and the reference consumer
  switches frames and windows.  The scheduled wrapper does `condition-case`
  + `message` so a buggy callback is reported, not lost.  `"auth denied"`
  → one `message` telling the user to allow Emacs in System Settings →
  Notifications.
- Callback table pruning: macOS never reports a dismissed or expired
  notification without a custom category, so entries for un-clicked
  notifications stay.  Ids are a monotonic counter, so after each insert
  drop every key below `(- counter 256)`; hash-table iteration order is
  not age after `remhash`, so never prune by `maphash` order.  Upgrade
  path if this matters: a `UNNotificationCategory` with
  `UNNotificationCategoryOptionCustomDismissAction` gives `:on-close` for
  the explicit-dismiss case only.
- `kill-emacs`: nothing to do; the pipe dies with the process.

Docstrings: short, one-line purpose plus essentials.  No prose about what
was changed or why an option is absent.

## Tests

`macos-notifications-tests.el`, run by `make test`:

1. Lisp dispatch without the native side: bind the hash table and the
   pending-line variable, call `macos-notifications--filter` directly with
   `nil` as the process and chunks split mid-line (`"12 def"` then
   `"ault\n13 default\n"`), run pending timers (`timer-event-handler` on
   the scheduled timers, or `(accept-process-output nil 0.1)`), assert both
   callbacks ran with the right args and were removed from the table.
2. Pruning: insert 300 ids with clicks interleaved, assert the surviving
   keys are exactly the newest 256.
3. Module load: `(require 'macos-notifications-module)` succeeds in batch.
   The GUI gate: `macos-notifications-notify` signals the `user-error` in
   batch (`window-system` is nil) *before* touching the module.  Do not
   assert anything about bundle state in batch: on this machine
   `/opt/homebrew/bin/emacs` is a wrapper that execs the Emacs.app binary,
   so a batch Emacs *is* bundled, while nix/CI Emacs is not; and a batch
   Emacs does not ignore SIGPIPE (`src/sysdep.c`, `noninteractive` branch),
   so a channel write landing after exit would kill the test run.  The
   ObjC exception path (unregistered bundle) stays a manual check.

The real click path cannot be automated (nobody clicks in CI).  Manual
verification checklist, done in the user's running Emacs.app before
declaring the feature done:

- `(macos-notifications-notify :title "t" :body "b" :on-action (lambda (id key) (message "clicked %s %s" id key)))`
  → banner with the Emacs icon appears **while Emacs is frontmost** (tests
  the `willPresent` delegate), click → `*Messages*` shows `clicked N default`.
- Same with Emacs in the background, click → Emacs activates and the
  message appears.
- `:replaces-id` with the previous id while the banner is still visible
  replaces it instead of stacking.
- `macos-notifications-close` removes a delivered notification from
  Notification Center.
- `emacs -nw`: `macos-notifications-notify` → the GUI `user-error`; no
  delegate is installed.
- Exception path once: run the bundle binary from a copy of Emacs.app in a
  directory LaunchServices has never seen (`cp -R` into the scratchpad,
  launch `Contents/MacOS/Emacs` directly), call `macos-notifications-notify`
  → a Lisp error naming the bundle problem, Emacs stays alive.

## CI (`.github/workflows/ci.yml`)

Copy sodium's workflow, macOS only.  `purcell/setup-emacs` gives a
non-bundled Emacs, which is exactly the test-3 path; the module still
builds and loads there.  Jobs: lint (package-lint + byte-compile with
`byte-compile-error-on-warn`) and test on `28.2` and `snapshot`.
`brew`-nothing: clang comes with the runner.

## README

Short: what it does, why a module (three sentences from "Why this package
exists"), install (`package-vc-install` or MELPA once there, first load
offers to compile), the API with one example, the two requirements
(Emacs.app GUI build, Emacs 28.1+), and the limits (no icon override, no
dismiss callback, clicks after Emacs quit are lost since the posting
process is gone).

MELPA recipe (later):
`(macos-notifications :fetcher github :repo "dakra/macos-notifications" :files (:defaults "*.m" "emacs-module.h" "Makefile"))`
(`:defaults` keeps MELPA's exclusion of `*-tests.el`; a bare `("*.el" ...)`
list would ship the test file).

## Out of scope for v1

- Action buttons (`:actions`), `:on-close`, `:timeout`, `:urgency`,
  `:app-name`, `:image-path`: macOS has no equivalent or no API.
- An `alert` style.  Trivial to add in personal config or as a follow-up
  (`alert-define-style 'macos-notifications :notifier ...`), and alert must
  stay an optional dependency; package-lint rejects
  `with-eval-after-load`, so if it ever ships it goes in a separate
  `macos-notifications-alert.el`.
- Delegate registration at app launch (clicks that *start* Emacs).

## Consumer: ghostel (personal config, not part of this package)

This package was prompted by Claude Code running inside ghostel.  The chain
today: Claude Code sees `TERM_PROGRAM=ghostty` and emits OSC 777 →
ghostel `ghostel--handle-notification` → `ghostel-notification-functions`
(default `(ghostel-default-notify)`; `ghostel-taskbar-mode` adds
`ghostel-taskbar--alert` in front) →
`ghostel-default-notify` → `alert` with `alert-default-style` =
`osx-notifier` → `do-applescript "display notification"`.  Clicking that
notification does nothing useful (no delegate; and LaunchServices on this
Mac holds two stale `org.gnu.Emacs` registrations pointing into an
unmounted Time Machine snapshot, which is the likely cause of the
"choose an application" dialog).

Hook functions in `ghostel-notification-functions` are called with `(TITLE
BODY)`, the originating ghostel buffer current, already deferred off the
output path via `ghostel--defer`.  An empty TITLE means iTerm2-style OSC 9;
use the buffer name then.  Multiple Emacs frames are in use, so the click
handler must select the frame showing the buffer, not just the selected one.

Snippet for `~/.emacs.d/init.el` once the package works:

```elisp
(defun dakra-ghostel-notify (title body)
  "Native macOS notification; clicking it shows the originating buffer."
  (let ((buf (current-buffer)))
    (macos-notifications-notify
     :title (if (string-empty-p title) (buffer-name) title)
     :body body
     :on-action
     (lambda (_id _key)
       (when (buffer-live-p buf)
         (let ((win (get-buffer-window buf t)))
           (if win
               (progn (select-frame-set-input-focus (window-frame win))
                      (select-window win))
             (select-frame-set-input-focus (selected-frame))
             (pop-to-buffer buf))))))))

(with-eval-after-load 'ghostel-status
  (remove-hook 'ghostel-notification-functions #'ghostel-default-notify)
  (add-hook 'ghostel-notification-functions #'dakra-ghostel-notify))
```

`ghostel-taskbar--alert` stays on the hook (it only flags attention in the
taskbar).  Nothing in ghostel itself changes; ghostel's README could later
mention the package next to `ghostel-tty-forward-notify`.

Independent cleanup worth doing regardless (fixes focus for every other
Emacs-posted notification, e.g. mu4e's):

```
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -u "/Volumes/.timemachine/39F62435-3823-4106-9C4C-F24A2035B896/2026-10-07-113314.backup/2026-10-07-113314.backup/Data/Applications/Emacs.app"
$LSR -u "/Volumes/.timemachine/39F62435-3823-4106-9C4C-F24A2035B896/2026-10-07-113314.backup/2026-10-07-113314.backup/Data/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app"
```

## Environment facts (verified 2026-10-20)

- Emacs 32.0.50, emacs-plus@32, NS build, `window-system` = `ns`, running
  from `/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app`
  (`/Applications/Emacs.app` is a symlink chain to it).  Bundle id
  `org.gnu.Emacs`.
- `module-file-suffix` = `.dylib`; `make-pipe-process` available.
- `/opt/homebrew/bin/emacs` is a shell wrapper exec'ing
  `Emacs.app/Contents/MacOS/Emacs`, so batch runs are bundled here.
  `(featurep 'ns)` is `t` and `(window-system)` is `nil` in `--batch`.
- macOS 26 (Darwin 25.6).  Emacs already has notification permission
  (the AppleScript notifications show), so `requestAuthorization` should
  return granted without a prompt.
- Claude Code 2.1.304 picks the notification channel from `TERM_PROGRAM`;
  `ghostty` → "Ghostty (OSC 777)".

## Working conventions for this repo

- Feature branches; never commit or push without an explicit per-action
  request; no AI attribution anywhere in commits, PRs, code, or docs.
- Plan first, present it, then implement; stick to the plan; call out
  deviations.
- Minimal code: no options or abstractions beyond this plan.  Concise
  docstrings and comments describing current behaviour only.
- Run `make lint test` before asking for a commit.
- Verify the click path manually in the user's live Emacs.app (the
  checklist above) before claiming it works.
