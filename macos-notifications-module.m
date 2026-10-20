/* macos-notifications-module.m --- Native macOS notifications for Emacs

   Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.  */

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "emacs-module.h"

int plugin_is_GPL_compatible;

/* Write end of the Lisp pipe process, -1 until `--open' is called.
   Written from framework callback threads; nothing there may touch
   emacs_env.  */
static int channel_fd = -1;

static void
channel_write (const char *line)
{
  size_t len = strlen (line);
  while (len > 0)
    {
      ssize_t n = write (channel_fd, line, len);
      if (n < 0)
        {
          if (errno == EINTR)
            continue;
          return;
        }
      line += n;
      len -= (size_t) n;
    }
}

@interface MacosNotificationsDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation MacosNotificationsDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))handler
{
  handler (UNNotificationPresentationOptionBanner
           | UNNotificationPresentationOptionList
           | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))handler
{
  NSString *action = response.actionIdentifier;
  if ([action isEqualToString:UNNotificationDefaultActionIdentifier])
    action = @"default";
  NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                             response.notification.request.identifier, action];
  channel_write (line.UTF8String);
  handler ();
}

@end

static MacosNotificationsDelegate *delegate;

static emacs_value
nil_value (emacs_env *env)
{
  return env->intern (env, "nil");
}

static emacs_value
signal_error (emacs_env *env, const char *msg)
{
  emacs_value data = env->make_string (env, msg, (ptrdiff_t) strlen (msg));
  emacs_value payload = env->funcall (env, env->intern (env, "list"), 1, &data);
  env->non_local_exit_signal (env, env->intern (env, "error"), payload);
  return nil_value (env);
}

/* Lisp string V as an NSString, or nil after signaling.  */
static NSString *
to_nsstring (emacs_env *env, emacs_value v)
{
  ptrdiff_t size = 0;
  if (!env->copy_string_contents (env, v, NULL, &size))
    return nil;
  char *buf = malloc ((size_t) size);
  if (buf == NULL)
    {
      signal_error (env, "Out of memory");
      return nil;
    }
  if (!env->copy_string_contents (env, v, buf, &size))
    {
      free (buf);
      return nil;
    }
  NSString *s = [NSString stringWithUTF8String:buf];
  free (buf);
  return s;
}

static NSString *
id_string (emacs_env *env, emacs_value v)
{
  intmax_t id = env->extract_integer (env, v);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return nil;
  return [NSString stringWithFormat:@"%jd", id];
}

static emacs_value
Fopen (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  int fd = env->open_channel (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return nil_value (env);
  /* dup2 swaps the target atomically, so a callback thread holding
     the old number keeps a valid descriptor.  */
  if (channel_fd >= 0)
    {
      dup2 (fd, channel_fd);
      close (fd);
    }
  else
    channel_fd = fd;

  if (delegate == nil)
    {
      @try
        {
          UNUserNotificationCenter *center
            = [UNUserNotificationCenter currentNotificationCenter];
          delegate = [MacosNotificationsDelegate new];
          center.delegate = delegate;
          [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert
                                                   | UNAuthorizationOptionSound)
                  completionHandler:^(BOOL granted, NSError *error) {
              (void) error;
              channel_write (granted ? "auth granted\n" : "auth denied\n");
            }];
        }
      @catch (NSException *e)
        {
          delegate = nil;
          NSString *msg = [NSString stringWithFormat:
                                      @"Notifications unavailable: %@ (Emacs must run "
                                      @"from an app bundle registered with LaunchServices)",
                                    e.reason];
          return signal_error (env, msg.UTF8String);
        }
    }
  return nil_value (env);
}

static emacs_value
Fnotify (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  NSString *ident = id_string (env, args[0]);
  NSString *title = ident ? to_nsstring (env, args[1]) : nil;
  NSString *body = title ? to_nsstring (env, args[2]) : nil;
  if (body == nil)
    return nil_value (env);
  if (delegate == nil)
    return signal_error (env, "Notification center not initialized");

  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  content.title = title;
  content.body = body;
  if (env->is_not_nil (env, args[3]))
    content.sound = UNNotificationSound.defaultSound;
  UNNotificationRequest *request
    = [UNNotificationRequest requestWithIdentifier:ident content:content trigger:nil];
  [[UNUserNotificationCenter currentNotificationCenter]
    addNotificationRequest:request
    withCompletionHandler:^(NSError *error) {
      if (error != nil)
        channel_write ("auth denied\n");
    }];
  return nil_value (env);
}

static emacs_value
Fclose (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  NSString *ident = id_string (env, args[0]);
  if (ident == nil || delegate == nil)
    return nil_value (env);
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center removePendingNotificationRequestsWithIdentifiers:@[ ident ]];
  [center removeDeliveredNotificationsWithIdentifiers:@[ ident ]];
  return nil_value (env);
}

static void
defun (emacs_env *env, const char *name, ptrdiff_t arity,
       emacs_value (*fn) (emacs_env *, ptrdiff_t, emacs_value *, void *),
       const char *doc)
{
  emacs_value args[2] = { env->intern (env, name),
                          env->make_function (env, arity, arity, fn, doc, NULL) };
  env->funcall (env, env->intern (env, "defalias"), 2, args);
}

int
emacs_module_init (struct emacs_runtime *ert)
{
  if ((size_t) ert->size < sizeof *ert)
    return 1;
  emacs_env *env = ert->get_environment (ert);
  if ((size_t) env->size < sizeof (struct emacs_env_28))
    return 2;

  defun (env, "macos-notifications--open", 1, Fopen,
         "Route notification events into pipe PROCESS and install the delegate.\n\n"
         "(fn PROCESS)");
  defun (env, "macos-notifications--notify", 4, Fnotify,
         "Post a notification ID with TITLE and BODY, playing the default sound if SOUND.\n\n"
         "(fn ID TITLE BODY SOUND)");
  defun (env, "macos-notifications--close", 1, Fclose,
         "Remove notification ID from Notification Center.\n\n(fn ID)");

  emacs_value feature = env->intern (env, "macos-notifications-module");
  env->funcall (env, env->intern (env, "provide"), 1, &feature);
  return 0;
}
