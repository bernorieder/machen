# How machen works

Technical notes for developers. For using machen, see the [README](../README.md); for building it, see [Building and releasing](building.md).

machen is a SwiftUI menu bar app (`MenuBarExtra` in window style) that talks directly to the Google Calendar API and the Google Tasks API, for each connected Google account. There's no server of its own.

## Code map

| File | What it does |
| --- | --- |
| `App.swift` | App entry, the menu bar item, switching between the list, the editors and Settings; keeps the panel hanging from the menu bar |
| `AgendaView.swift` | The main list: section and group headings, event and task rows, Join button, Undo banner |
| `Editors.swift` | Event and task editors, including "This event / All events" and Add Subtask |
| `SettingsViews.swift` | Sign-in screen and the three Settings pages |
| `Store.swift` | All synced data of all accounts, the sync schedule, sending edits to the right account, the offline cache, scheduling reminders |
| `Accounts.swift` | The `Account` protocol the store works with, and the list of connected accounts, kept in the Keychain |
| `GoogleAccount.swift` | A Google account: its tokens, Google's API types, loading calendars, events, lists and tasks, and edits |
| `Models.swift` | Calendars, events, lists and tasks as machen shows them, edit drafts, ordering rules, meeting-link detection, series shifting |
| `Notifications.swift` | Turning reminders into Mac notifications, and the Join action |
| `GoogleAuth.swift` | Google sign-in (OAuth 2.0 with PKCE and a loopback redirect) and token refresh |
| `GoogleAPI.swift` | Authorized JSON requests, URL building and Google's date formats |
| `Util.swift` | Keychain access, colours, settings enums, text sizes |
| `Layout.generated.swift` | Layout constants generated from `Support/layout.json`; don't edit |

## Accounts

- **One protocol:** the store works with `Account` (in `Accounts.swift`): load calendars, events, task lists and tasks, and save, complete and delete. `GoogleAccount` is the only kind so far; other kinds, such as calendars on the Mac, would be added beside it.
- **Ids:** an account's id is `google-` and 8 random hex digits. A calendar's or list's id in machen is the account id, a slash, and the id at Google (`CalendarInfo.id`, `TaskListInfo.id`), because the same calendar can belong to two accounts. Settings (shown calendars, order, list colours, folded lists) use these ids.
- **Shared calendars:** a calendar that an earlier account has too, such as a shared or a holiday calendar, starts hidden in the later account, so its events don't appear twice.
- **Address:** a Google account is named by its address, which is the id of its primary calendar. After sign-in machen asks for that calendar's id (`calendars/primary?fields=id`), so no extra permission is needed. Signing in to an account that's already connected renews its sign-in.
- **Editing:** edits go to the account the calendar or list belongs to. An event can move between calendars of its account, but not to another account, which Google doesn't support.
- **Removing:** revokes machen's access at Google, drops the tokens, and forgets that account's settings, calendars, events and tasks. Removing the last account deletes the offline cache.
- **From machen 1.x:** version 1.x had one account. On the first launch of a version with several accounts, its tokens become the first account, the settings get that account's id in front of every calendar and list id, and the old Keychain item is emptied. The old cache doesn't decode any more and is replaced by the first sync.

## Sign-in

- machen uses Google's flow for desktop apps. It opens the browser and listens on `127.0.0.1` at a random port for Google's redirect. A PKCE code challenge and a random `state` value protect the exchange. If nothing comes back within 5 minutes, sign-in is cancelled.
- Google is asked to show its account chooser (`prompt=select_account consent`), so another account can be added while the browser is signed in to one. Signing in again to an expired account passes its address as `login_hint`.
- It asks for offline access, so Google returns a refresh token. All accounts and their tokens are stored in one Keychain item (service `local.machen`, account `google-accounts`).
- Each account refreshes its access token shortly before it expires. If Google rejects the refresh token (`invalid_grant`), for example after access was revoked, that account is signed out: its events and tasks are hidden, Settings → Sources offers **Sign In Again**, and the list shows a note until then. If no account is left signed in, the sign-in screen shows. Removing an account while a refresh is under way doesn't bring it back.
- Accounts coming and going are handled by the store, not by a view, so the cleanup also happens when the panel hasn't been opened yet.
- The OAuth client normally comes built into the app; see [building.md](building.md#1-set-up-a-google-project-one-time).

## Keychain

A legacy Keychain item belongs to the app that created it.

- **Signature:** an item created by a Developer ID build is tied to the team's signature, so every later build with the same signature reads it without asking. An item created by an ad-hoc build trusts only that exact build, which is why ad-hoc builds ask after every rebuild.
- **Writing:** machen always updates its item in place, also when accounts are added or removed, since they all share one item. Any build may do that without asking. Deleting the item would need the owner's permission, which always asks.
- **Emptying:** the item of machen 1.x (account `tokens`) is emptied after it's carried over, which is also an update, so it doesn't ask either.

## Syncing

The intervals are in the `Sync` enum in `Store.swift`.

| When | What |
| --- | --- |
| At launch | Everything: calendars, task lists, events, tasks |
| Opening the panel | Events near today and tasks (everything if the 5-minute sync is due), unless something was refreshed in the last 10 seconds |
| Every minute | Events near today |
| Every 5 minutes | Everything |
| 5 seconds after waking from sleep | Everything |
| After an edit | The part that changed, in the background |

- **Independent parts:** calendars with their events, and task lists with their tasks, load side by side and independently, and so do accounts. If the Tasks API fails, events still update, and the other way round; if one account can't be reached, it keeps what it had while the others update. Errors name the account when there are several. The 5-minute timer restarts even after a failure, so a failing part doesn't turn every minute into a full sync.
- **Edits come first:** every local edit (completing a task, saving an event and so on) marks the data as changed, and results from a fetch that started before the edit are thrown away. The edit's own refresh brings the final state.

### Events

- **The 5-minute sync** loads 28 days ahead while notifications are on: 4 weeks is Google's maximum reminder time, so reminders like "1 week before" work. With notifications off it loads only the days shown.
- **The minute refresh** reloads the days shown, but at least two, so reminders for early tomorrow stay current. It keeps the events loaded further ahead.
- **Changing the number of days** shows already-loaded days right away, and loads more only if needed, after a short pause so several clicks on the stepper load once.
- **Requests stay small:** repeating events are expanded into single occurrences (`singleEvents=true`), and every request asks only for the fields machen uses (`fields=items(…)`, so no guest lists, for example).
- **Shown calendars only:** only calendars switched on in **Settings → Sources** are loaded. Hiding a calendar or list just filters what's loaded; showing one loads it.
- **Cost:** each load costs one request per shown calendar, plus one more for each further page of 250 events.

### Tasks

Tasks are loaded per list with `showCompleted=false`. Within a list, top-level tasks are sorted by due date, with undated ones last, then by Google's own order; subtasks follow their parent in Google's order. With the **Due date only** filter, an undated parent stays visible if one of its subtasks has a date.

### Quota

Google's default quota is 1 million Calendar requests a day for all users of a Google project together, and much less for Tasks. One person with 8 calendars uses about 8 Calendar requests a minute. If many people share a project, lengthen the intervals or ask Google for a higher quota.

## Offline cache

The last loaded calendars, task lists, tasks and events of all accounts, and the 4-week reminder window, are stored in `~/Library/Application Support/io.github.bernorieder.machen/cache.json`, readable only by the user (`0600`). machen shows them right away at launch, then refreshes. The cached events are only reused on the same day. The file is only rewritten when its contents change, not for every refresh. Removing the last account deletes it.

## Notifications

- **What becomes a notification:** each popup reminder of an event, that is the event's own reminders or, if it uses the defaults, its calendar's default reminders. Email reminders are left to Google. Declined events are skipped.
- **Scheduling:** notifications are scheduled with macOS's `UserNotifications` after every sync, and already at launch from the cache. Only new or changed reminders are handed to macOS; ones no longer wanted are removed. At most the 60 soonest are scheduled at a time. Scheduling runs after the loading spinner stops, because the first time macOS may wait for an answer to its permission prompt.
- **Removing:** when machen quits, it removes its pending notifications, because macOS would deliver them without asking machen. They're also removed when the last account is removed or signed out, and when **Event notifications** is switched off. Events of a signed-out account get no notifications.
- **Join:** a notification for an event with a video call has a **Join** button.
- **Permission:** macOS asks for permission the first time. If it's denied, Settings says so and links to System Settings.

## Repeating events

When you edit one occurrence of a repeating event, the editor offers **This event** and **All events**.

- **This event:** changes only the occurrence.
- **All events:** changes the series. Only what you changed is sent. A new time moves the series' first event by the same amount, in the series' own time zone, and gives it the new length. For example, moving a 09:00 New York meeting to 10:00 keeps it at 10:00 New York time, also across a clock change.
- **Refused for whole series:** moving to other days, and switching between all-day and timed. The repeat rule (for example "every Monday") would keep the old day, so these need Google Calendar.
- **Moving to another calendar:** Google moves only whole series, so the calendar picker unlocks for **All events** only.
- **Deleting:** either the occurrence or the whole series.

## Multi-day events

An event counts as multi-day if it's an all-day event longer than one day, or a timed event of 24 hours or more. An overnight event such as 22:00–06:00 doesn't count. **Settings → General → Multi-day events** decides where they appear:

- **Show on every day:** under every day the event covers.
- **Show on today and start day:** once, under the first shown day the event covers. That's Today for an event already running; an event starting later appears on its start day, marked "Starts".
- **Exclude:** not shown at all.

## Video call links

An event's call link is, in this order:

1. the video link of its conference data (Google Meet, or an add-on such as Zoom),
2. its `hangoutLink`,
3. the first link in its location or description whose host is one of: Google Meet, Zoom, Microsoft Teams, Webex, Whereby, GoToMeeting, Jitsi Meet, FaceTime.

The **Join** button turns blue from 10 minutes before the start until the end.

## The panel

macOS doesn't reliably resize a menu bar panel when its content changes height, and when it does, it keeps the bottom edge in place. `PanelTopAnchor` in `App.swift` sets the window's frame itself: the chosen height, with the top edge where macOS put it under the menu bar.

## Settings storage

Settings are stored in the app's preferences, `~/Library/Preferences/io.github.bernorieder.machen.plist`. They're separate from the accounts, which are in the Keychain, and from the cache.
