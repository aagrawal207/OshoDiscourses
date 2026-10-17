# Google Drive sync

Android replaces the iOS iCloud key-value sync with one JSON file in the user's own
Google Drive **app-data folder**. That folder is hidden from the Drive UI and from every
other app. The app requests only the `https://www.googleapis.com/auth/drive.appdata`
scope, so it cannot see any of the user's other files. There is no developer server.

Code: `android/sync` (`DriveSyncController`, `DriveSyncEngine`, `OkHttpDriveApi`,
`GoogleDriveAuthorizer`, `DriveSyncWorker`).

## How it works

- **What syncs.** The same `CloudSnapshot` as iOS: recent positions and durations,
  completed and recently played lists, play history, bookmarks and bookmark tombstones,
  daily listening seconds, download history, and transcript anchors and read positions.
  Settings stay on the device. The file is `appDataFolder/cloud.progress.v1.json`.
- **Opt-in.** iOS needs no toggle because iCloud is already signed in. Android needs the
  user's consent first, so sync stays off until the user taps the Sync row in Settings.
  That shows Google's consent screen for the app-data scope. After that, launches
  re-authorize silently. A revoked grant shows "sign in needed"; it never pops up a
  consent screen by itself.
- **When it runs.**
  - Pull and merge on launch, when the app comes to the foreground (at most every 30 s),
    and every 6 hours from a WorkManager job while the app is closed.
  - Push after local changes: progress auto-saves, bookmark add and remove, stats,
    transcript state and download history. A change waits 5 s to collect a burst of
    edits, and pushes are at least 30 s apart. This is not a pure debounce, because
    playback saves every 10 s and a quiet gap never comes while listening.
  - When the app goes to the background with unsent changes, a network-constrained
    WorkManager job pushes them, so they survive process death.
- **Each round is read-merge-write.** List the file, download it if its `version`
  changed since the last round, merge it into the repositories, then export the merged
  state. If the export equals the remote content, nothing is written. Otherwise the app
  re-reads `version` and writes only if it did not move. If it moved, the round starts
  again (3 attempts).
- **Lost-update safety.** Drive v3 has no ETag or `If-Match` precondition, so a write
  from another device can still land in the gap between the version check and the
  upload. Nothing is lost. That device still has its data locally. On its next round it
  sees that the remote copy lacks that data, and pushes the merged result. The merge rules
  are convergent and idempotent (union, max, newest wins), so devices agree whatever the
  write order.
- **Two first syncs at once** can create two files. The next round merges every copy into
  the oldest file and deletes the others.
- **Status.** `SyncStatus` is `SignInNeeded` until the user connects, `Syncing` during a
  round, `UpToDate(lastSyncedAt)` after one, and `Failed(message)` when offline or when
  Drive fails. Offline and server errors are retried by WorkManager when the network
  returns. Setup errors (Drive API disabled, wrong SHA-1) are not retried.
- **Sign out** turns sync off and clears the cached token. **Disconnect**
  (`DriveSyncController.disconnect()`) also revokes the app's grant on the Google
  account. Neither deletes the Drive file. A user can delete it in Google Drive >
  Settings > Manage apps > Osho Talks > Options > Delete hidden app data.

## One-time Google Cloud setup

You need a Google account that can create Cloud projects. Use the same project for debug
and release.

1. **Create the project.** Open <https://console.cloud.google.com/>, select the project
   picker, then **New project**. Name it `Osho Talks`.
2. **Enable the Drive API.** Go to **APIs & Services > Library**, search for
   **Google Drive API**, and select **Enable**. If you skip this step, every request
   fails with `403 accessNotConfigured`, and the app shows "Couldn't connect to Google Drive."
3. **Configure the OAuth consent screen.** Go to **Google Auth Platform** (formerly
   **APIs & Services > OAuth consent screen**).
   1. **Branding:** app name `Osho Talks`, a user support email, and a developer contact
      email. Add the privacy policy URL
      (`https://github.com/aagrawal207/OshoDiscourses/blob/main/PRIVACY.md`) and the home
      page if you have them.
   2. **Audience:** user type **External**.
   3. **Data access:** select **Add or remove scopes**, and add
      `https://www.googleapis.com/auth/drive.appdata` ("See, create, and delete its own
      configuration data in your Google Drive"). Google lists it as **non-sensitive**,
      so it needs no security assessment or scope verification.
   4. While the app is in **Testing**, only listed test users can grant access. Add the
      Google accounts you test with under **Audience > Test users**. Grants made in
      Testing can expire after 7 days; reconnect from Settings if that happens.
   5. Before release, select **Publish app** (**Audience > In production**). With only a
      non-sensitive scope, no Google review is needed. Google may still ask for brand
      verification if you upload a logo.
4. **Create the Android OAuth clients.** Go to **Google Auth Platform > Clients >
   Create client** and select application type **Android**. Create one client for each
   signing certificate below, all with package name `com.agraabhi.oshodiscourses`:

   | Client name | SHA-1 from |
   | --- | --- |
   | `Android debug` | your debug keystore (each developer machine has its own) |
   | `Android upload` | the upload key you sign release bundles with |
   | `Android Play signing` | Play Console's app signing key (the key on users' devices) |

   The app needs no client ID or JSON file. Google Identity Services matches the
   package name and signing certificate of the running app against these clients. Do
   not create a Web client; the app does not request offline access.

### Getting the SHA-1 fingerprints

Debug key (created by Android Studio on first build):

```sh
keytool -list -v -keystore ~/.android/debug.keystore \
  -alias androiddebugkey -storepass android -keypass android | grep SHA1
```

Or let Gradle print every variant's signing certificate:

```sh
cd android && ./gradlew :app:signingReport
```

Upload key (replace the path and alias with yours; keytool asks for the password):

```sh
keytool -list -v -keystore /path/to/upload-keystore.jks -alias upload | grep SHA1
```

Play App Signing key: in Play Console, open the app, then **Test and release > Setup >
App signing** (older consoles: **Release > Setup > App integrity**). Copy the
**SHA-1 certificate fingerprint** under **App signing key certificate**. Builds that
users install from Play are signed with this key, so sync fails in production without
this client even if the upload-key client works.

## Testing on the emulator

1. In Android Studio's Device Manager, create a device with a **Google Play** system
   image (the image name says "Google Play", and the device shows a Play Store icon).
   A "Google APIs" image without Play also works; plain AOSP images do not, because
   they have no Google Play services.
2. Boot it, open **Settings > Passwords & accounts** (or **Google**), and sign in with a
   Google account. While the consent screen is in Testing, use a listed test user.
3. Install the debug build: `cd android && ./gradlew :app:installDebug`.
4. Open the app, go to **Settings**, and tap the **Sync** row. Choose the account and
   allow access. The row should then show that sync is up to date.
5. Play a talk for a minute, then add a bookmark. Within about 30 s the push runs.
6. Check that the data came through, with either method:
   - **Reinstall:** `adb uninstall com.agraabhi.oshodiscourses`, install again, connect
     sync in Settings. Progress, bookmarks and stats come back.
   - **Second device:** boot a second emulator with the same account, connect sync, and
     check Home > Continue Listening and Bookmarks.

   Google Drive > Settings > **Manage apps** also lists Osho Talks with "Hidden app data"
   once the file exists.
7. **Offline:** turn on airplane mode in the emulator, make a change, and open
   Settings. The row shows the offline message. Turn the network back on; WorkManager
   pushes the change.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| "Couldn't connect to Google Drive." right after the account picker | The running build's SHA-1 or package has no Android client (`DEVELOPER_ERROR`, status 10). Check `signingReport` against the clients. |
| "Couldn't connect to Google Drive." after consent succeeded | Drive API not enabled for the project (`403 accessNotConfigured`). |
| Consent says "Access blocked: app has not completed verification" | The account is not a test user, and the app is still in Testing. |
| Status keeps returning to "sign in needed" weekly | Testing-mode grants expire. Publish the consent screen. |
| Works in debug, fails from Play | The Play App Signing SHA-1 client is missing. |
