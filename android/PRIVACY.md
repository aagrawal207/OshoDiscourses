# Privacy Policy (Android)

**Osho Talks** for Android has no developer-operated servers and includes no advertising or tracking SDKs. It sends anonymous usage data, described below, which you can turn off. The developer never receives anything that identifies you.

## What the app does

- Downloads audio files from oshoworld.com or an Internet Archive mirror to your device
- Fetches discourse transcripts from oshoworld.com and caches them on your device
- Checks about once a day for a newer list of talks and downloads it from GitHub, or from the jsDelivr CDN when GitHub cannot be reached
- Stores your settings, bookmarks and playback progress on your device
- If you turn it on, syncs your playback progress, bookmarks and listening stats across your own devices through a hidden app folder in your own Google Drive. The developer has no server and never receives this data.

## Data stored on your device

- **Settings:** your preferences (theme, language, playback options)
- **Bookmarks:** timestamps and notes you create
- **Playback position:** which discourse you were listening to and where you stopped
- **Listening stats:** how long you listen each day, used for the in-app stats and streak
- **Downloaded files:** audio files you choose to download. They are excluded from Android backup, because they can be downloaded again.
- **List of talks:** the newest list the app has downloaded, with the time of its next check. It is excluded from Android backup, because it can be downloaded again.
- **Optional tips:** Google Play order IDs and a device-local tip count prevent counting a tip twice. Tips unlock no content or features.
- **Rating and support reminders:** request dates and your reminder choice are stored on this device to limit reminders. Anonymous usage data may record that a reminder was shown, but not when.

Settings, bookmarks, progress and stats can be included in your device's Android backup, which Google stores in your Google account under Android's backup settings. Downloaded audio is not included.

## Anonymous usage data

To learn which features and talks people use, and what to improve, the app sends anonymous usage data to [TelemetryDeck](https://telemetrydeck.com/privacy/), an analytics service based in the European Union.

- **What is sent:** which features are used (for example playback, downloads, Smart Download, Smart Delete, DeNoise and its mode, transcripts, bookmarks and the sleep timer), the app's settings, which series and discourse is played, how long a talk is listened to, whether a download succeeded and how fast it was, whether an optional tip was bought, and general device details such as device model, screen size, system version, app version, language, region and time zone, accessibility settings such as text size, and whether the app was installed from Google Play.
- **What is never sent:** your name, email, Google account, contacts or location; bookmark notes; what you type in search; transcript text; and the audio itself.
- **How it is sent:** most use is counted on your device and sent as a summary about once a day, together with the talks you listened to.
- **No identity:** the app uses a random identifier for this installation, which is hashed on the device before it is sent. The data is not linked to you, is not used to track you across apps or websites, and is not sold or used for advertising.
- **Turn it off:** Settings > About > Share Anonymous Usage Data. When it is off, the app sends nothing.

## Google Drive sync

Sync is off until you tap the Sync row in Settings and allow access. The app then asks Google only for the `drive.appdata` permission. With it, the app can see and change only its own hidden file in your Drive. It cannot see any of your other files.

The file contains your recent playback positions and durations, finished and recently played talks, play history, bookmarks, daily listening time, download history and transcript reading positions. Settings stay on the device. The file goes only to your Google Drive; the developer never receives it.

To stop syncing, use Settings > Sync in the app. To delete the file, open Google Drive > Settings > Manage apps > Osho Talks > Options > Delete hidden app data.

## Network access

The app connects to oshoworld.com and archive.org to download audio and transcripts, to TelemetryDeck for the anonymous usage data, to Google Drive when sync is on, and to Google Play for tips and ratings.

About once a day the app fetches the list of talks from GitHub (raw.githubusercontent.com), or from the jsDelivr CDN (cdn.jsdelivr.net) when GitHub cannot be reached. The request carries nothing about you or your listening: no cookie and no identifier. Like any web request, it shows that server your IP address. The developer does not receive it.

## Third-party services

- Oshoworld.com and archive.org host the audio files and transcripts.
- GitHub and jsDelivr host the list of talks.
- Google Drive stores the optional sync file in your own account.
- Google Play Billing handles payment for optional tips. The app records tips locally; it has no purchase server.
- Google Play In-App Review may show a rating card. Google decides when it appears.
- TelemetryDeck receives the anonymous usage data described above.

Google's services handle data under [Google's Privacy Policy](https://policies.google.com/privacy), and TelemetryDeck under [its own](https://telemetrydeck.com/privacy/). The app includes no advertising or tracking services.

## Permissions

- **Notifications:** show playback controls and download progress.
- **Network and background work:** download talks you choose, including when the app is closed, and run sync.
- **Foreground services:** keep playback and downloads running while you use other apps.

## Children

The app is not directed at children and does not knowingly collect personal information from anyone.

## Analytics and tracking

The app uses TelemetryDeck only for the anonymous usage data described above. It does not use advertising identifiers, does not track you across apps or websites, and has no ads.

## Contact

If you have questions about this privacy policy, open an issue at https://github.com/aagrawal207/OshoDiscourses/issues

---

Last updated: November 2026
