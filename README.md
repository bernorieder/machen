# machen

A small macOS menu bar app for Google Calendar and Google Tasks.

Click the calendar icon in the menu bar to see:

- **Events** from every calendar you have visible in Google Calendar, for today or for the next several days (see Settings). Events use their own colour if you gave them one in Google Calendar, and their calendar's colour otherwise.
- **Open tasks**, grouped by task list. Each list has a colour bar, like calendar events do. Within a list, tasks are sorted by due date: overdue ones first (in red), undated ones last. Subtasks appear indented and in smaller type below their parent, in the order you gave them in Google Tasks.

You can add events and tasks with the **+** buttons. A list's own **+** adds a task to that list. To add a subtask, open a task and click **Add Subtask**. Click an event or task to edit or delete it. Click the circle next to a task to mark it as done. Events from calendars you can't edit open in Google Calendar instead.

Requires macOS 14 or later.

## 1. Create a Google OAuth client (one time)

Google requires every app that uses its APIs to have its own client ID. It's free and takes about five minutes.

1. Open <https://console.cloud.google.com/> and create a new project (for example "machen").
2. Go to **APIs & Services → Library** and enable both **Google Calendar API** and **Google Tasks API**.
3. Go to **Google Auth Platform** (or **APIs & Services → OAuth consent screen**):
   - Choose **External** as the user type and fill in the app name and your email.
   - Under **Audience**, add your own Google address as a **test user**.
4. Go to **Clients** (or **Credentials → Create credentials → OAuth client ID**), choose application type **Desktop app**, and create it.
5. Copy the **Client ID** and **Client secret**.

> **About the 7-day sign-out:** while the app's publishing status is *Testing*, Google expires refresh tokens after 7 days, so you'd have to sign in again every week. To avoid that, go to **Audience** and click **Publish app**. For personal use you don't need verification. You'll just see an "unverified app" warning once when you sign in. Click **Advanced → Go to machen**.

## 2. Build and run

You need Xcode or the Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open build/machen.app
```

To install, move `build/machen.app` to `/Applications`. Then turn on **Settings → Launch at login** if you want it to start automatically.

## 3. Sign in

Click the menu bar icon, paste your client ID and secret, and click **Sign in with Google**. Your browser opens. Approve access, then click the menu bar icon again.

## Notes

- **Storage:** the sign-in token is stored in your macOS Keychain. The client ID and secret are stored in the app's preferences. (Google doesn't treat a Desktop client secret as confidential.)
- **Keychain prompt after rebuilds:** the build is ad-hoc signed, so after each rebuild macOS may ask once whether machen can use its Keychain item. Click **Always Allow**.
- **Display:** clicking the **Events** heading switches between Today, 2 days, 3 days and Week. In **Settings → Display** you can choose any number of days of events to show (1 to 14) and the row spacing (Compact, Standard or Roomy). When more than one day is shown, events are grouped under day headings. The **Multi-day events** menu sets how events lasting more than a day are handled: show them on every day they cover, show each one once, or exclude them. With **Show on today and start day**, an event running today appears once under Today. An event that starts later in the shown days appears once, on its start day, marked "Starts". (A multi-day event is an all-day event longer than one day, or a timed event lasting 24 hours or more. An overnight event such as 22:00–06:00 doesn't count.)
- **Tasks filter:** choose **All** or **Due date only**, either in Settings → Display or by clicking the **Tasks** heading in the main screen. With **Due date only**, a parent task without a date stays visible if one of its subtasks has a date.
- **Menu bar icon:** pick one of several icons in Settings → Display.
- **Links:** Settings has shortcuts to Google Calendar, Google Tasks, and this project on GitHub.
- **Choosing what's shown:** **Settings** (gear icon) lets you pick which calendars and task lists to show, and a colour for each task list. (Google Tasks lists have no colours of their own.) By default you see the calendars that are visible in Google Calendar, plus all task lists.
- **Sync:** the app loads everything when it starts. After that it refreshes when you open it (at most once a minute), every 5 minutes, and after every edit.
- **Limitations:**
  - Google Tasks only stores a due *date*, not a time.
  - After you create an event or task, you can't move it to a different calendar or list.
  - Editing a recurring event changes only that one occurrence.
  - Subtasks can only be one level deep, which is a Google Tasks limit.
  - Completing a task also completes its open subtasks, like the Google Tasks apps do.

## Code layout

| File | Purpose |
| --- | --- |
| `GoogleAuth.swift` | OAuth 2.0 browser sign-in (PKCE + loopback redirect), token refresh, Keychain storage |
| `GoogleAPI.swift` | Authorized JSON requests and URL building |
| `Models.swift` | API types, display models, and edit drafts |
| `Store.swift` | Fetching, sorting, and saving events and tasks |
| `AgendaView.swift` | The main popover list |
| `Editors.swift` | Event and task editors |
| `SettingsViews.swift` | Sign-in and settings screens |
