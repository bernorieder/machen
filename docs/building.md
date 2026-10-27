# Building and releasing machen

This page is for people who want to build machen themselves or publish a release. To just use machen, see the [README](../README.md).

## Requirements

- A Mac with Apple silicon and macOS 14 or later. `build.sh` builds for Apple silicon only.
- Xcode, or only the Command Line Tools (`xcode-select --install`). machen is a Swift package and builds without Xcode. This is why the views use a small `@ViewState` property wrapper instead of `@State`: in recent SDKs `@State` is a macro whose plugin ships only with Xcode.
- A Google Cloud project with an OAuth client (below).
- For a release: an Apple Developer ID certificate, and notarization credentials.

## 1. Set up a Google project (one time)

Every app that uses Google's APIs needs its own OAuth client. It's free.

1. Open <https://console.cloud.google.com/> and create a project, for example "machen".
2. Under **APIs & Services → Library**, enable the **Google Calendar API** and the **Google Tasks API**.
3. Under **Google Auth Platform** (or **APIs & Services → OAuth consent screen**):
   - Choose **External** as the user type, and fill in the app name and your email.
   - Under **Audience**, add your own Google address as a test user.
   - Under **Data Access**, add the three scopes machen asks for: `…/auth/calendar.calendarlist.readonly`, `…/auth/calendar.events` and `…/auth/tasks`.
4. Under **Clients** (or **Credentials → Create credentials → OAuth client ID**), create a client of type **Desktop app**.
5. Copy `Support/Config.example.plist` to `Support/Config.local.plist` and fill in the client ID and client secret. The file is gitignored. `build.sh` copies the values into the app, so people using your build only have to sign in. Without the file, the app asks for a client ID and secret on its sign-in screen instead.

Google doesn't treat a desktop client secret as confidential, since it ships inside every copy of the app. Still, keep it out of the public repository.

### Publishing status and verification

- **Testing:** only the test users you listed can sign in, and Google ends their sign-in after 7 days. Each Google account connected to machen must be on the list, including second accounts.
- **In production, unverified:** go to **Audience → Publish app**. Anyone can sign in, up to 100 users, and they see an "unverified app" warning once (**Advanced → Go to machen**).
- **Verified:** to remove the warning and the user limit, apply for verification on the same page. Google asks for a home page, a privacy policy, and a short video showing the sign-in. The events and tasks permissions are "sensitive", which needs this review but not the paid security assessment; the calendar list permission isn't sensitive.

### Website

machen's home page and privacy policy, which verification needs, are `docs/index.html` and `docs/privacy.html`, with `docs/site.css`. GitHub Pages serves the `docs/` folder of `main` at <https://machen.polsys.net>:

- **GitHub:** under the repository's **Settings → Pages**, the source is **Deploy from a branch**, `main`, `/docs`. `docs/CNAME` holds the domain, and `docs/.nojekyll` makes Pages serve the files as they are.
- **DNS:** `machen.polsys.net` is a CNAME record pointing to `bernorieder.github.io`.
- **Google:** `polsys.net` is verified in Google Search Console by an owner of the Google Cloud project, and listed under **Google Auth Platform → Branding → Authorized domains**, with the home page and privacy policy addresses.

Google requires the privacy policy to match what the app does. Update it, and its date, whenever machen starts handling data differently.

machen asks only for what it uses:

| Scope | What machen does with it |
| --- | --- |
| `…/auth/calendar.calendarlist.readonly` | Lists your calendars, with their names, colours and default reminders, and finds the account's address (its primary calendar's id) |
| `…/auth/calendar.events` | Shows, adds, changes, moves and deletes events, also in calendars shared with you |
| `…/auth/tasks` | Shows, adds, changes, moves, completes and deletes tasks, and creates task lists |

It doesn't ask for full calendar access (`…/auth/calendar`), which would also allow sharing, creating and deleting calendars. `calendar.events.owned` would be narrower still, but wouldn't allow editing events in calendars someone shared with you.

## 2. Build

```bash
./build.sh
open build/machen.app
```

`build.sh` does the following:

1. Turns `Support/layout.json` into `Sources/machen/Layout.generated.swift` (see [Layout values](#layout-values)).
2. Builds a release binary with `swift build -c release`.
3. Assembles `build/machen.app` with `Support/Info.plist`, the app icon, and the menu bar fist.
4. Adds the Google client from `Support/Config.local.plist`, if it exists.
5. Signs the app with the first **Developer ID Application** certificate in your keychain, with the hardened runtime. Without one it signs ad-hoc. Set `SIGN_IDENTITY` to choose a certificate. Apple's secure timestamp, which notarization needs, is only added for releases (`RELEASE=1`, set by `release.sh`), so everyday builds also work offline.

Ad-hoc builds ask for Keychain access after every rebuild, because each build has a different signature. Developer ID builds share your team's signature, so they don't. See [Keychain](how-it-works.md#keychain).

## 3. Release

Apple has to notarize an app that people download, or macOS won't open it.

One-time setup: create an app-specific password at <https://account.apple.com> → Sign-In and Security, then save the notarization credentials in your keychain:

```bash
xcrun notarytool store-credentials machen-notary --apple-id <your Apple ID> --team-id <your team ID>
```

For each release:

1. Raise `CFBundleShortVersionString` (for example `1.1`) and `CFBundleVersion` (for example `2`) in `Support/Info.plist`.
2. Run `./release.sh`. It checks that `Support/Config.local.plist` holds a real client ID, builds and signs the app, packs it into a disk image, has Apple notarize it, and staples the result. Only then does the disk image get its final name, `build/machen-<version>.dmg`, so an image that isn't notarized is never left there by mistake. Use `NOTARY_PROFILE` for a profile name other than `machen-notary`.
3. Publish it, for example with the GitHub CLI:

   ```bash
   gh release create v1.1 build/machen-1.1.dmg --title "machen 1.1" --notes "…"
   ```

## Tools

### Layout values

The spacing, size and font values of the main list live in `Support/layout.json`: row padding for each Spacing setting, heading paddings, indents, colour bars, base font sizes, panel width and heights, and the size of the menu bar fist. A few small elements keep fixed values in the code: the Join button, the Undo and error banners, and the footer. Keys starting with `_` are comments.

`Support/make-layout.swift` turns the file into Swift constants (`Layout.Bar.width` and so on) on every build. A typo, a missing value or a value that isn't a number stops the build and names the key or line.

### Screenshots

`Support/make-screenshots.sh` renders the images in `docs/screenshots` from the app's real views, filled with sample data, so no personal calendar data ends up in the repository. It builds a separate tool with `-D SCREENSHOTS`, which has its own bundle ID and settings, never reads the keychain, and cleans up after itself.

### App icon

`Support/make-icon.swift` draws the app icon (the Font Awesome fist on a white tile) and writes `Support/AppIcon.icns` and `Support/AppIcon.png`. Run it after changing the drawing:

```bash
swift Support/make-icon.swift
```
