# Privacy Policy

**Osho Talks** has no developer-operated servers and includes no analytics, advertising, or tracking SDKs. The developer does not receive your listening data.

## What the app does

- Downloads audio files from oshoworld.com or an Internet Archive mirror to your device
- Fetches discourse transcripts from oshoworld.com and caches them on your device
- Stores your settings, bookmarks, and playback progress on your device
- Syncs your playback progress, bookmarks, and listening stats across your own devices through your personal iCloud (Apple's iCloud Key-Value storage). This data goes only to your iCloud account. The developer has no server and never receives it. There is no account to create and no sign-in.

## Data stored on your device

- **Settings:** your preferences (theme, language, playback options) stored in UserDefaults
- **Bookmarks:** timestamps and notes you create, stored as a JSON file in the app's Documents folder
- **Playback position:** which discourse you were listening to and where you stopped
- **Listening stats:** how long you listen each day, used for the in-app stats and streak
- **Downloaded files:** audio files you choose to download, stored in the Documents folder (visible in Files app). These are not included in your iCloud backup, since they can be re-downloaded.
- **Optional tips:** verified StoreKit transaction IDs and their counted/revoked state, plus a device-local tip count, prevent duplicate counting. Tips unlock no content or features.

## iCloud sync

Your playback progress, bookmarks, and listening stats sync across devices signed in to the same Apple Account, through Apple's iCloud Key-Value storage. This uses your own iCloud. The data never reaches the developer, and you can turn sync off by disabling iCloud Drive for the app in iOS Settings.

## Apple Watch, CarPlay and Mac

- **Apple Watch:** the iPhone app talks to the Watch app directly through Apple's WatchConnectivity. When you save a talk to the Watch, a copy of the downloaded audio is sent to the Watch and stays there until you remove it on the Watch. It is excluded from device backup. The Watch sends your listening position back to the iPhone so it can continue where you stopped. This exchange stays between your own devices.
- **CarPlay:** CarPlay shows the lists and playback controls already on your iPhone. It collects no extra data.
- **Mac:** the Mac version stores the same data as the iPhone app, inside the app's sandbox container on your Mac. Syncing uses the same personal iCloud storage.

## Network access

The app connects to oshoworld.com and archive.org to download audio discourse files and transcripts. iCloud sync is handled by the operating system.

For recordings without matching bundled transcript timing, optional speech sync on
iOS 26 processes downloaded English or Hindi audio using Apple's on-device speech
recognisers. Recognition assets may require downloading; the recording is not uploaded.

## Third-party services

Oshoworld.com and archive.org host the audio files. Apple's iCloud service handles optional sync between your devices. The app does not include advertising or tracking services.

Optional tips use Apple's StoreKit in-app purchases. Apple handles the purchase;
the app records verified transaction state locally and has no purchase server.

## Analytics and tracking

The app has no developer-run analytics or tracking.

## Contact

If you have questions about this privacy policy, open an issue at https://github.com/aagrawal207/OshoDiscourses/issues

---

Last updated: October 2026
