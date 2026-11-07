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
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

#include "emacs-module.h"

int plugin_is_GPL_compatible;

/* Write end of the Lisp pipe process, -1 until `--open' is called.
   Only channel_queue touches it.  */
static int channel_fd = -1;

/* Serial queue all channel writes run on.  A write blocks while the
   pipe is full, and the main thread, where the delegate is called, is
   the one that reads the pipe.  */
static dispatch_queue_t channel_queue;

/* Send LINE to Lisp.  Callable from any thread; nothing reached from
   here may touch emacs_env.  */
static void
channel_write (NSString *line)
{
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_async (channel_queue, ^{
      const char *bytes = data.bytes;
      size_t len = data.length;
      while (len > 0)
        {
          ssize_t n = write (channel_fd, bytes, len);
          if (n < 0)
            {
              if (errno == EINTR)
                continue;
              return;
            }
          bytes += n;
          len -= (size_t) n;
        }
    });
}

/* TEXT encoded to fit in one field of a space-separated line.  */
static NSString *
encode (NSString *text)
{
  return [[text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES]
           base64EncodedStringWithOptions:0] ?: @"";
}

/* Marks the request identifiers of this Emacs session, which are
   SESSION.ID.SERIAL with ID the Lisp id.  */
static NSString *session;

/* "ID SERIAL", which names a post in its events, from request
   identifier IDENT, nil unless this session posted it: a notification
   outlives the session that posted it.  */
static NSString *
event_ids (NSString *ident)
{
  NSArray<NSString *> *parts = [ident componentsSeparatedByString:@"."];
  return (parts.count == 3 && [parts[0] isEqualToString:session]
          ? [NSString stringWithFormat:@"%@ %@", parts[1], parts[2]] : nil);
}

/* Serial queue all posting and removing of notifications runs on, in
   the order Lisp asked for it.  A notification posted before the
   authorization request completes is rejected, so the queue stays
   suspended until then.  */
static dispatch_queue_t center_queue;

/* The work on center_queue and the posts the framework has not
   answered yet.  */
static dispatch_group_t pending;

@interface MacosNotificationsDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation MacosNotificationsDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))handler
{
  /* The interruption level keeps a passive notification quiet too,
     but exists only from macOS 12 on.  */
  BOOL passive = [notification.request.content.userInfo[@"passive"] boolValue];
  handler (passive
           ? UNNotificationPresentationOptionList
           : (UNNotificationPresentationOptionBanner
              | UNNotificationPresentationOptionList
              | UNNotificationPresentationOptionSound));
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))handler
{
  NSString *ident = event_ids (response.notification.request.identifier);
  NSString *action = response.actionIdentifier;
  NSString *line;
  if (ident == nil)
    {
      handler ();
      return;
    }
  if ([response isKindOfClass:[UNTextInputNotificationResponse class]])
    {
      NSString *text = ((UNTextInputNotificationResponse *) response).userText;
      line = [NSString stringWithFormat:@"%@ reply %@\n", ident, encode (text)];
    }
  else
    {
      if ([action isEqualToString:UNNotificationDefaultActionIdentifier])
        action = @"default";
      else if ([action isEqualToString:UNNotificationDismissActionIdentifier])
        action = @"dismiss";
      line = [NSString stringWithFormat:@"%@ %@\n", ident, action];
    }
  channel_write (line);
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
signal_condition (emacs_env *env, const char *symbol, const char *msg)
{
  emacs_value data = env->make_string (env, msg, (ptrdiff_t) strlen (msg));
  emacs_value payload = env->funcall (env, env->intern (env, "list"), 1, &data);
  env->non_local_exit_signal (env, env->intern (env, symbol), payload);
  return nil_value (env);
}

static emacs_value
signal_error (emacs_env *env, const char *msg)
{
  return signal_condition (env, "error", msg);
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
  /* SIZE counts the trailing NUL.  Emacs encodes a lone surrogate as
     it is, which is not UTF-8.  */
  NSString *s = [[NSString alloc] initWithBytes:buf length:(NSUInteger) size - 1
                                       encoding:NSUTF8StringEncoding];
  free (buf);
  if (s == nil)
    signal_error (env, "String is not valid UTF-8");
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

/* Lisp id V as a string.  */
static NSString *
id_string (emacs_env *env, emacs_value v)
{
  intmax_t id = env->extract_integer (env, v);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return nil;
  return [NSString stringWithFormat:@"%jd", id];
}

/* Category with ACTIONS (key, label, ...), a text field with
   placeholder REPLY and a reported DISMISS, nil when none is needed.
   The identifier is derived from the contents, so that all Emacs.app
   processes, which share one set of categories, name the same category
   alike.  */
static UNNotificationCategory *
category_for (NSArray<NSString *> *actions, NSString *reply, BOOL dismiss)
{
  if (actions.count == 0 && reply == nil && !dismiss)
    return nil;
  NSData *json = [NSJSONSerialization
                   dataWithJSONObject:@[ actions, reply ?: NSNull.null, @(dismiss) ]
                              options:0 error:NULL];
  NSString *ident = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
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
  return [UNNotificationCategory categoryWithIdentifier:ident
                                                actions:list
                                      intentIdentifiers:@[]
                                                options:(dismiss ? UNNotificationCategoryOptionCustomDismissAction : 0)];
}

/* Answer to a notification center query, nil if none arrives within
   a few seconds: START gets the block to hand to the query as its
   completion handler.  Blocks the calling thread, so not for use
   inside a completion handler, where waiting holds up the answers to
   all other queries.  */
static id
await (void (^start) (void (^) (id)))
{
  dispatch_semaphore_t done = dispatch_semaphore_create (0);
  __block id result;
  start (^(id value) {
      result = value;
      dispatch_semaphore_signal (done);
    });
  if (dispatch_semaphore_wait (done, dispatch_time (DISPATCH_TIME_NOW,
                                                    5 * NSEC_PER_SEC)))
    return nil;
  return result;
}

/* Size of the registered set at which unused categories get dropped,
   and number of recently used categories kept in any case.  */
enum { MAX_CATEGORIES = 64, RECENT_CATEGORIES = 16 };

/* The categories the last notifications were posted with, oldest
   first.  A notification is listed as delivered only a moment after it
   was posted; until then this is what tells that its category is in
   use.  Only center_queue touches it.  */
static NSMutableArray<UNNotificationCategory *> *recent_categories;

/* The categories registered for this app bundle, nil without an
   answer.  */
static NSSet<UNNotificationCategory *> *
registered_categories (UNUserNotificationCenter *center)
{
  return await (^(void (^reply) (id)) {
      [center getNotificationCategoriesWithCompletionHandler:reply];
    });
}

/* Whether the category named IDENT is in REGISTERED.  */
static BOOL
has_category (NSSet<UNNotificationCategory *> *registered, NSString *ident)
{
  return [[registered valueForKey:@"identifier"] containsObject:ident];
}

/* Add CATEGORY to the registered set unless it is there, along with
   the other recent ones.  Only once the set has grown large are
   categories dropped, those that neither a delivered notification nor
   a recent post uses.  Return whether CATEGORY is registered.  */
static BOOL
add_category (UNUserNotificationCenter *center, UNNotificationCategory *category)
{
  NSSet<UNNotificationCategory *> *registered = registered_categories (center);
  /* Without an answer the set is best left alone.  */
  if (registered == nil)
    return NO;
  if (has_category (registered, category.identifier))
    return YES;
  NSArray<UNNotification *> *delivered = nil;
  if (registered.count >= MAX_CATEGORIES)
    delivered = await (^(void (^reply) (id)) {
        [center getDeliveredNotificationsWithCompletionHandler:reply];
      });
  if (delivered != nil)
    {
      NSMutableSet<NSString *> *used = [NSMutableSet new];
      for (UNNotification *notification in delivered)
        {
          NSString *ident = notification.request.content.categoryIdentifier;
          if (ident != nil)
            [used addObject:ident];
        }
      registered = [registered objectsPassingTest:^BOOL (UNNotificationCategory *c, BOOL *stop) {
          (void) stop;
          return [used containsObject:c.identifier];
        }];
    }
  [center setNotificationCategories:
            [registered setByAddingObjectsFromArray:recent_categories]];
  /* Reading the set back also waits for the update, which the next
     process to take the lock has to see.  */
  return has_category (registered_categories (center), category.identifier);
}

/* Make sure CATEGORY is registered and return whether it is.  macOS
   keeps one set of categories per app bundle, shared by all Emacs.app
   processes and outliving them, and shows no buttons on a notification
   whose category is not in the set.  The framework can only replace
   the whole set, so a file lock keeps the processes from undoing each
   other's updates.  A process that holds it for seconds is stuck, and
   then not waited for.  Runs on center_queue.  */
static BOOL
register_category (UNUserNotificationCenter *center, UNNotificationCategory *category)
{
  if (recent_categories == nil)
    recent_categories = [NSMutableArray new];
  [recent_categories removeObject:category];
  [recent_categories addObject:category];
  if (recent_categories.count > RECENT_CATEGORIES)
    [recent_categories removeObjectAtIndex:0];

  NSString *path = [NSTemporaryDirectory ()
                     stringByAppendingPathComponent:@"macos-notifications.lock"];
  int lock = open (path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  for (int tries = 0; lock >= 0 && tries < 100 && flock (lock, LOCK_EX | LOCK_NB) != 0; tries++)
    usleep (50000);
  BOOL registered = add_category (center, category);
  if (lock >= 0)
    close (lock);
  return registered;
}

/* By Lisp id, the request identifier of its latest post.  Only
   center_queue touches it.  */
static NSMutableDictionary<NSString *, NSString *> *posted;

/* Remove the notification with Lisp id ID.  Runs on center_queue.  */
static void
retract (UNUserNotificationCenter *center, NSString *id)
{
  NSString *ident = posted[id];
  if (ident == nil)
    return;
  [posted removeObjectForKey:id];
  [center removePendingNotificationRequestsWithIdentifiers:@[ ident ]];
  [center removeDeliveredNotificationsWithIdentifiers:@[ ident ]];
}

/* Tell Lisp that the post with event ids IDS had a problem.  */
static void
report_error (NSString *ids, NSString *description)
{
  channel_write ([NSString stringWithFormat:@"error %@ %@\n", ids, encode (description)]);
}

/* Attachment for the image file at PATH, nil on failure, with ERROR
   set if there is one to report.  The framework moves an attached file
   into its own store once the notification is posted, so the
   attachment is a copy, at *COPY.  */
static UNNotificationAttachment *
image_attachment (NSString *path, NSURL **copy, NSError **error)
{
  NSURL *src = [NSURL fileURLWithPath:path];
  NSURL *target = src.URLByResolvingSymlinksInPath;
  /* The extension tells the framework the image type.  */
  NSString *ext = src.pathExtension.length > 0 ? src.pathExtension : target.pathExtension;
  NSString *name = [@"macos-notifications-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory ()] URLByAppendingPathComponent:name];
  if (ext.length > 0)
    tmp = [tmp URLByAppendingPathExtension:ext];
  NSFileManager *files = [NSFileManager defaultManager];
  if (![files copyItemAtURL:target toURL:tmp error:error])
    return nil;
  UNNotificationAttachment *attachment
    = [UNNotificationAttachment attachmentWithIdentifier:@"image" URL:tmp
                                                 options:nil error:error];
  if (attachment == nil)
    [files removeItemAtURL:tmp error:NULL];
  else
    *copy = tmp;
  return attachment;
}

/* Whether this process runs an executable inside an app bundle, also
   when started through a symlink to it.  */
static BOOL
in_app_bundle (void)
{
  char path[PATH_MAX], real[PATH_MAX];
  uint32_t size = sizeof path;
  if (_NSGetExecutablePath (path, &size) != 0 || realpath (path, real) == NULL)
    return NO;
  NSString *dir = @(real).stringByDeletingLastPathComponent;
  if (![dir hasSuffix:@"/Contents/MacOS"])
    return NO;
  NSString *app = dir.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
  return [NSBundle bundleWithPath:app].bundleIdentifier != nil;
}

static emacs_value
Fopen (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  /* Outside an app bundle the notification center throws from inside
     dispatch_once, where no @catch gets to see it.  */
  if (delegate == nil && !in_app_bundle ())
    return signal_condition (env, "user-error",
                             "Notifications need Emacs running from its app bundle");
  int fd = env->open_channel (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return nil_value (env);
  /* Keep the pipe out of the subprocesses Emacs starts.  */
  fcntl (fd, F_SETFD, FD_CLOEXEC);
  /* Swap on the queue, so that every line goes to one pipe as a whole.  */
  dispatch_async (channel_queue, ^{
      if (channel_fd >= 0)
        close (channel_fd);
      channel_fd = fd;
    });

  if (delegate == nil)
    {
      UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
      delegate = [MacosNotificationsDelegate new];
      center.delegate = delegate;
      dispatch_suspend (center_queue);
      [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert
                                               | UNAuthorizationOptionSound)
              completionHandler:^(BOOL granted, NSError *error) {
          (void) granted; (void) error;
          dispatch_resume (center_queue);
        }];
    }
  return nil_value (env);
}

/* Number of notifications posted.  Only calls from Lisp touch it, which
   run one at a time.  */
static long long posts;

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
  BOOL named = env->eq (env, env->type_of (env, args[3]), env->intern (env, "string"));
  NSString *sound = named ? to_nsstring (env, args[3]) : nil;
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return nil_value (env);
  if (delegate == nil)
    return signal_error (env, "Notification center not initialized");

  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  content.title = title;
  content.body = body;
  if (sound != nil)
    content.sound = [UNNotificationSound soundNamed:sound];
  else if (env->is_not_nil (env, args[3]))
    content.sound = UNNotificationSound.defaultSound;
  UNNotificationCategory *category
    = category_for (actions, reply, env->is_not_nil (env, args[6]));
  if (category != nil)
    content.categoryIdentifier = category.identifier;
  BOOL passive = env->is_not_nil (env, args[7]);
  content.userInfo = @{ @"passive" : @(passive) };
  if (@available (macOS 12.0, *))
    if (passive)
      content.interruptionLevel = UNNotificationInterruptionLevelPassive;
  NSURL *copy = nil;
  if (image != nil)
    {
      NSError *error = nil;
      UNNotificationAttachment *attachment = image_attachment (image, &copy, &error);
      if (attachment == nil)
        return signal_error (env, (error.localizedDescription
                                   ?: @"Cannot attach the image").UTF8String);
      content.attachments = @[ attachment ];
    }
  /* An identifier serves one post only: the framework drops both
     notifications when one is posted with the identifier of another
     that is not delivered yet, or was just removed.  */
  long long serial = ++posts;
  NSString *request_ident = [NSString stringWithFormat:@"%@.%@.%lld", session, ident, serial];
  NSString *ids = event_ids (request_ident);
  UNNotificationRequest *request
    = [UNNotificationRequest requestWithIdentifier:request_ident content:content trigger:nil];
  dispatch_group_async (pending, center_queue, ^{
      UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
      if (category != nil && !register_category (center, category))
        report_error (ids, @"Cannot register the notification's buttons");
      retract (center, ident);
      posted[ident] = request_ident;
      dispatch_group_enter (pending);
      [center addNotificationRequest:request
               withCompletionHandler:^(NSError *error) {
          if (error != nil)
            {
              /* A post that fails leaves the image copy behind.  */
              if (copy != nil)
                [[NSFileManager defaultManager] removeItemAtURL:copy error:NULL];
              if ([error.domain isEqualToString:UNErrorDomain]
                  && error.code == UNErrorCodeNotificationsNotAllowed)
                channel_write ([NSString stringWithFormat:@"denied %@\n", ids]);
              else
                report_error (ids, error.localizedDescription);
            }
          dispatch_group_leave (pending);
        }];
    });
  return env->make_integer (env, serial);
}

static emacs_value
Fclose (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  NSString *ident = id_string (env, args[0]);
  if (ident == nil || delegate == nil)
    return nil_value (env);
  dispatch_group_async (pending, center_queue, ^{
      retract ([UNUserNotificationCenter currentNotificationCenter], ident);
    });
  return nil_value (env);
}

static emacs_value
Fflush (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  (void) nargs; (void) args; (void) data;
  dispatch_group_wait (pending, dispatch_time (DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
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

  channel_queue = dispatch_queue_create ("macos-notifications.channel",
                                         DISPATCH_QUEUE_SERIAL);
  center_queue = dispatch_queue_create ("macos-notifications.center",
                                        DISPATCH_QUEUE_SERIAL);
  pending = dispatch_group_create ();
  posted = [NSMutableDictionary new];
  session = NSUUID.UUID.UUIDString;

  defun (env, "macos-notifications--open", 1, Fopen,
         "Route notification events into pipe PROCESS and install the delegate.\n\n"
         "(fn PROCESS)");
  defun (env, "macos-notifications--notify", 9, Fnotify,
         "Post notification ID with TITLE and BODY and return the post's serial.\n"
         "SOUND is nil, t for the default sound or a sound name.  ACTIONS is a\n"
         "vector of KEY LABEL strings.  REPLY is a placeholder string for a text\n"
         "field or nil.  DISMISS non-nil reports an explicit dismissal.  PASSIVE\n"
         "non-nil delivers quietly.  IMAGE is a local image file or nil.\n\n"
         "(fn ID TITLE BODY SOUND ACTIONS REPLY DISMISS PASSIVE IMAGE)");
  defun (env, "macos-notifications--close", 1, Fclose,
         "Remove notification ID from Notification Center.\n\n(fn ID)");
  defun (env, "macos-notifications--flush", 0, Fflush,
         "Wait up to two seconds for requests to reach Notification Center.");

  emacs_value feature = env->intern (env, "macos-notifications-module");
  env->funcall (env, env->intern (env, "provide"), 1, &feature);
  return 0;
}
