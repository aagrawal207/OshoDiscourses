# Privacy Policy

**Osho Talks** has no developer-operated servers and includes no advertising or tracking SDKs. It sends anonymous usage data, described below, which you can turn off. The developer never receives anything that identifies you.

## What the app does

- Downloads audio files from oshoworld.com or an Internet Archive mirror to your device
- Fetches discourse transcripts from oshoworld.com and caches them on your device
- Checks about once a day for a newer list of talks and downloads it from GitHub, or from the jsDelivr CDN when GitHub cannot be reached
- Optionally translates a transcript on your device with Apple Translation and creates narration using a system voice
- Stores your settings, bookmarks, and playback progress on your device
- Syncs your playback progress, bookmarks, and listening stats across your own devices through your personal iCloud (Apple's iCloud Key-Value storage). This data goes only to your iCloud account. The developer has no server and never receives it. There is no account to create and no sign-in.

## Data stored on your device

- **Settings:** your preferences (theme, language, playback options) stored in UserDefaults
- **Bookmarks:** timestamps and notes you create, stored as a JSON file in the app's Documents folder
- **Playback position:** which discourse you were listening to and where you stopped
- **Listening stats:** how long you listen each day, used for the in-app stats and streak
- **Downloaded files:** audio files you choose to download, stored in the Documents folder (visible in Files app). These are not included in your iCloud backup, since they can be re-downloaded.
- **List of talks:** the newest list the app has downloaded, with the time of its next check. It is not included in device backup, since it can be downloaded again.
- **Optional tips:** verified StoreKit transaction IDs and their counted/revoked state, plus a device-local tip count, prevent duplicate counting. Tips unlock no content or features.
- **Optional yearly support:** the app checks verified subscription status through Apple to show your current plan and avoid duplicate subscriptions. A pending product is remembered locally until approval or until you explicitly clear a declined request, and the app remembers on this device whether the last check found a plan. There is no developer-run subscription database. All content and features remain free.
- **Rating and support reminders:** request dates and your support-reminder choice are stored on this device to limit reminders. Anonymous usage data may record that a reminder was shown, but not when.
- **Translated narration:** translated text, completed audio and partial preparation checkpoints stay on your device and are excluded from device backup. Playback positions are separate from the original recordings.

## Anonymous usage data

To learn which features and talks people use, and what to improve, the app sends anonymous usage data to [TelemetryDeck](https://telemetrydeck.com/privacy/), an analytics service based in the European Union.

- **What is sent:** which features are used (for example playback, downloads, Smart Download, Smart Delete, DeNoise and its mode, translation, transcripts, bookmarks, sleep timer, CarPlay and Apple Watch), whether a paired Apple Watch has the app, the app's settings, which series and discourse is played, downloaded or bookmarked, how long a talk is listened to, whether a download or translation succeeded and how fast a download was, whether an optional tip or yearly support was bought, and general device details such as device type, system version, app version, language and region settings.
- **What is never sent:** your name, email, Apple Account, contacts or location; bookmark notes; what you type in search; transcript text; and the audio itself.
- **How it is sent:** most use is counted on your device and sent as a summary about once a day, together with the talks you listened to.
- **No identity:** the app uses a random identifier for this installation, which is hashed on the device before it is sent. The data is not linked to you, is not used to track you across apps or websites, and is not sold or used for advertising.
- **Turn it off:** Settings > About > Share Anonymous Usage Data. When it is off, the app sends nothing.

## iCloud sync

Your playback progress, bookmarks, and listening stats sync across devices signed in to the same Apple Account, through Apple's iCloud Key-Value storage. This uses your own iCloud. The data never reaches the developer, and you can turn sync off by disabling iCloud Drive for the app in iOS Settings.

Generated narration and its playback positions are not live-synced. Their positions
use ordinary device settings storage, which can be included in device backup.

## Apple Watch, CarPlay and Mac

- **Apple Watch:** the iPhone app talks to the Watch app directly through Apple's WatchConnectivity. When you save a talk to the Watch, a copy of the downloaded audio is sent to the Watch and stays there until you remove it on the Watch. It is excluded from device backup. The Watch sends your listening position back to the iPhone so it can continue where you stopped. This exchange stays between your own devices.
- **CarPlay:** CarPlay shows the lists and playback controls already on your iPhone. Anonymous usage data may record that CarPlay was used.
- **Mac:** the Mac version stores the same data as the iPhone app, inside the app's sandbox container on your Mac. Syncing uses the same personal iCloud storage.

## Network access

The app connects to oshoworld.com and archive.org to download audio discourse files and transcripts. iCloud sync is handled by the operating system.

About once a day the app fetches the list of talks from GitHub (raw.githubusercontent.com), or from the jsDelivr CDN (cdn.jsdelivr.net) when GitHub cannot be reached. The request carries nothing about you or your listening: no cookie and no identifier. Like any web request, it shows that server your IP address and the version of the app. The developer does not receive it.

For recordings without matching bundled transcript timing, optional speech sync on
iOS 26 processes downloaded English or Hindi audio using Apple's on-device speech
recognisers. Recognition assets may require downloading; the recording is not uploaded.

Translated narration may require language or system-voice downloads from Apple.
According to [Apple's TranslationSession documentation](https://developer.apple.com/documentation/translation/translationsession),
translation is processed on your device. Apple may collect API usage and performance
metrics, including the app bundle ID and language pair, but not the original or
translated text. The developer does not receive the text or generated audio.

## Third-party services

Oshoworld.com and archive.org host the audio files. Apple's iCloud service handles optional sync between your devices. TelemetryDeck receives the anonymous usage data described above. The app does not include advertising or tracking services.

Optional tips and yearly support use Apple's StoreKit in-app purchases. Apple
handles payment, subscription renewals and cancellations. The app records tip
transactions locally and checks subscription status with Apple; it has no purchase server.

## Analytics and tracking

The app uses TelemetryDeck only for the anonymous usage data described above. It does not use advertising identifiers, does not track you across apps or websites, and has no ads.

## Contact

If you have questions about this privacy policy, open an issue at https://github.com/aagrawal207/OshoDiscourses/issues

---

Last updated: November 2026
