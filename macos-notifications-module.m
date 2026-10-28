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
  NSString *ident = response.notification.request.identifier;
  NSString *action = response.actionIdentifier;
  NSString *line;
  /* Notifications left over from an earlier Emacs session carry its pid.  */
  NSString *prefix = [NSString stringWithFormat:@"%d-", getpid ()];
  if (![ident hasPrefix:prefix])
    {
      handler ();
      return;
    }
  ident = [ident substringFromIndex:prefix.length];
  if ([response isKindOfClass:[UNTextInputNotificationResponse class]])
    {
      /* Percent-encode so the text fits in one space-separated line.  */
      NSString *text = ((UNTextInputNotificationResponse *) response).userText;
      NSString *encoded = [text stringByAddingPercentEncodingWithAllowedCharacters:
                                  NSCharacterSet.alphanumericCharacterSet];
      line = [NSString stringWithFormat:@"%@ reply %@\n", ident, encoded];
    }
  else
    {
      if ([action isEqualToString:UNNotificationDefaultActionIdentifier])
        action = @"default";
      else if ([action isEqualToString:UNNotificationDismissActionIdentifier])
        action = @"dismiss";
      line = [NSString stringWithFormat:@"%@ %@\n", ident, action];
    }
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

/* Lisp string V as an NSString, nil for a Lisp nil.  */
static NSString *
opt_nsstring (emacs_env *env, emacs_value v)
{
  return env->is_not_nil (env, v) ? to_nsstring (env, v) : nil;
}

/* Vector of Lisp strings V as an array, empty for a Lisp nil.  */
static NSArray<NSString *> *
to_strings (emacs_env *env, emacs_value v)
{
  NSMutableArray *array = [NSMutableArray new];
  if (!env->is_not_nil (env, v))
    return array;
  ptrdiff_t n = env->vec_size (env, v);
  for (ptrdiff_t i = 0; i < n; i++)
    {
      NSString *s = to_nsstring (env, env->vec_get (env, v, i));
      if (s == nil)
        return nil;
      [array addObject:s];
    }
  return array;
}

/* Request identifier for Lisp id V, prefixed with this process's pid.  */
static NSString *
id_string (emacs_env *env, emacs_value v)
{
  intmax_t id = env->extract_integer (env, v);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return nil;
  return [NSString stringWithFormat:@"%d-%jd", getpid (), id];
}

/* Categories by identifier, one per (ACTIONS REPLY DISMISS) used.  */
static NSMutableDictionary<NSString *, UNNotificationCategory *> *categories;

/* Identifier of the category with ACTIONS (key, label, ...), a text
   field with placeholder REPLY and a reported DISMISS, nil when no
   category is needed.  macOS keeps one category set per app bundle and
   another Emacs.app process replaces it with its own, after which
   notifications with an unknown category show no buttons.  Hence
   identifiers derived from the contents, so all processes agree on
   them, and the whole set re-registered on every call.  */
static NSString *
category_for (NSArray<NSString *> *actions, NSString *reply, BOOL dismiss)
{
  if (actions.count == 0 && reply == nil && !dismiss)
    return nil;
  NSData *json = [NSJSONSerialization
                   dataWithJSONObject:@[ actions, reply ?: NSNull.null, @(dismiss) ]
                              options:0 error:NULL];
  NSString *ident = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
  if (categories == nil)
    categories = [NSMutableDictionary new];
  if (categories[ident] == nil)
    {
      NSMutableArray *list = [NSMutableArray new];
      for (NSUInteger i = 0; i + 1 < actions.count; i += 2)
        [list addObject:[UNNotificationAction actionWithIdentifier:actions[i]
                                                             title:actions[i + 1]
                                                           options:0]];
      if (reply != nil)
        [list addObject:[UNTextInputNotificationAction actionWithIdentifier:@"reply"
                                                                      title:@"Reply"
                                                                    options:0
                                                       textInputButtonTitle:@"Send"
                                                       textInputPlaceholder:reply]];
      categories[ident]
        = [UNNotificationCategory categoryWithIdentifier:ident
                                                 actions:list
                                       intentIdentifiers:@[]
                                                 options:(dismiss ? UNNotificationCategoryOptionCustomDismissAction : 0)];
    }
  [[UNUserNotificationCenter currentNotificationCenter]
    setNotificationCategories:[NSSet setWithArray:categories.allValues]];
  return ident;
}

/* Attachment for the image file at PATH, copied first because the
   framework moves attached files into its own store.  nil with ERROR
   set on failure.  */
static UNNotificationAttachment *
image_attachment (NSString *path, NSError **error)
{
  NSURL *src = [NSURL fileURLWithPath:path];
  NSString *name = [@"macos-notifications-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory ()] URLByAppendingPathComponent:name];
  if (src.pathExtension.length > 0)
    tmp = [tmp URLByAppendingPathExtension:src.pathExtension];
  if (![[NSFileManager defaultManager] copyItemAtURL:src toURL:tmp error:error])
    return nil;
  UNNotificationAttachment *attachment
    = [UNNotificationAttachment attachmentWithIdentifier:@"image" URL:tmp
                                                 options:nil error:error];
  if (attachment == nil)
    [[NSFileManager defaultManager] removeItemAtURL:tmp error:NULL];
  return attachment;
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
  NSArray<NSString *> *actions = body ? to_strings (env, args[4]) : nil;
  NSString *reply = actions ? opt_nsstring (env, args[5]) : nil;
  NSString *image = actions ? opt_nsstring (env, args[8]) : nil;
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return nil_value (env);
  if (delegate == nil)
    return signal_error (env, "Notification center not initialized");

  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  content.title = title;
  content.body = body;
  emacs_value sound = args[3];
  if (env->eq (env, env->type_of (env, sound), env->intern (env, "string")))
    content.sound = [UNNotificationSound soundNamed:to_nsstring (env, sound)];
  else if (env->is_not_nil (env, sound))
    content.sound = UNNotificationSound.defaultSound;
  content.categoryIdentifier
    = category_for (actions, reply, env->is_not_nil (env, args[6]));
  if (@available (macOS 12.0, *))
    if (env->is_not_nil (env, args[7]))
      content.interruptionLevel = UNNotificationInterruptionLevelPassive;
  if (image != nil)
    {
      NSError *error = nil;
      UNNotificationAttachment *attachment = image_attachment (image, &error);
      if (attachment == nil)
        return signal_error (env, error.localizedDescription.UTF8String);
      content.attachments = @[ attachment ];
    }
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
  defun (env, "macos-notifications--notify", 9, Fnotify,
         "Post notification ID with TITLE and BODY.\n"
         "SOUND is nil, t for the default sound or a sound name.  ACTIONS is a\n"
         "vector of KEY LABEL strings.  REPLY is a placeholder string for a text\n"
         "field or nil.  DISMISS non-nil reports an explicit dismissal.  PASSIVE\n"
         "non-nil delivers quietly.  IMAGE is a local image file or nil.\n\n"
         "(fn ID TITLE BODY SOUND ACTIONS REPLY DISMISS PASSIVE IMAGE)");
  defun (env, "macos-notifications--close", 1, Fclose,
         "Remove notification ID from Notification Center.\n\n(fn ID)");

  emacs_value feature = env->intern (env, "macos-notifications-module");
  env->funcall (env, env->intern (env, "provide"), 1, &feature);
  return 0;
}
