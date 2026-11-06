# Google Play release

The steps from no Play account to a public release (GitHub issue #19). Products
are in [`play-products.md`](play-products.md), Drive sync setup in
[`google-drive-sync.md`](google-drive-sync.md), listing text and form answers in
[`play-store/listing.md`](play-store/listing.md).

## Release build

| Item | Value |
| --- | --- |
| Package | `com.agraabhi.oshodiscourses` |
| Version | `versionName` and `versionCode` in `app/build.gradle.kts`; first release `1.0.0` (1). Raise `versionCode` for every upload |
| Upload key | `~/.android/osho-talks/upload-keystore.jks` on the owner's Mac, alias `upload`, password in the macOS Keychain item "Osho Talks Android upload key" |
| Upload key SHA-1 | `91:59:7F:05:C8:DB:EC:33:97:F3:1E:1D:21:F5:4D:33:65:C8:DB:8F` |
| Upload key SHA-256 | `9C:E9:0A:ED:C6:ED:B4:86:E2:3C:22:67:C0:C4:A0:A0:FD:E0:FC:93:7D:3C:7D:A3:F6:B0:A5:38:00:41:7C:DE` |
| Signing properties | `osho.uploadStoreFile`, `osho.uploadStorePassword`, `osho.uploadKeyAlias`, `osho.uploadKeyPassword` in `~/.gradle/gradle.properties` |
| Licensing key | `osho.playLicenseKey`, from Play Console > Monetize with Play > Monetization setup |

```sh
./gradlew :app:bundleRelease -Posho.playLicenseKey="$KEY"
# app/build/outputs/bundle/release/app-release.aab
```

`checkPlayRelease` stops the bundle when the licensing key or upload key is
missing. Play App Signing holds the key that signs what users install; the
upload key only proves an upload came from the owner. If the upload key is lost,
Play Console support can reset it, but keep a backup of the keystore and its
password outside this Mac.

## Play Console

1. **Developer account** (<https://play.google.com/console/signup>): a personal
   account, US$25, government ID check, and a check of an Android phone through
   the Play Console app.
2. **Create the app**: name "Osho Talks - Audio Discourses", default language
   English (United States), app, free, with the declarations accepted.
3. **App content**: every form in `play-store/listing.md`.
4. **Store listing**: text and graphics from `play-store/listing.md`, plus phone
   screenshots.
5. **Payments profile** and the licensing key, which the bundle needs.
6. **Internal testing**: upload the first bundle, add the owner's account, and
   install from the opt-in link.
7. **Products** from `play-products.md`. Play allows them only after a bundle
   with billing is uploaded.
8. **App signing SHA-1**: copy it from Test and release > Setup > App signing
   and add the Android OAuth clients in `google-drive-sync.md`.
9. **Closed testing**: personal accounts created after 13 November 2023 need at
   least 12 testers opted in for 14 days in a row before applying for
   production. Updates during the test do not restart the 14 days.
10. **Apply for production** on the Dashboard, then create the production
    release. Google reviews it, usually within a few days.

## Before each upload

- `./gradlew testDebugUnitTest` passes.
- The bundle installs from the testing track on a real phone: playback with the
  screen off, notification controls, downloads, DeNoise, transcript, Drive sync
  and a test-card tip.
- Store text and release notes match the build.
