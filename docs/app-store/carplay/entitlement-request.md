# CarPlay audio entitlement request

Submitted through Apple's form at <https://developer.apple.com/contact/carplay/>
by Abhishek Agrawal for team `W2NS9DM63G`. **Submitted 2026-10-02**: App Type Audio,
CarPlay Entitlement Addendum agreed. Apple showed "Thank you for your submission"
and will reply by email. **Approved** the same day.

After approval (2026-10-02):
- The `CarPlay Audio App (CarPlay framework)` capability is enabled in the developer
  portal on App IDs `com.agraabhi.oshodiscourses` (`5QAL7DM3R8`) and
  `com.agraabhi.ganabajana` (`F2YP24T626`, Breezy). The grant is per category and
  account, so Breezy needed no separate request. The public API reports it as
  `CARPLAY_PLAYABLE_CONTENT` but cannot enable it; that was done in the portal.
- Enabling it invalidated the earlier App Store profiles (`75U9NAWQ5L`, `93TB48J488`).
  Replacement: `A8XF3V4XNH`, "Osho Talks App Store CarPlay 2026-10-02", UUID
  `3ce85c0f-4e34-4b8c-93dc-d5a8494f5be4`, certificate `W7NQ25R66K`. Its entitlements
  include `com.apple.developer.carplay-audio`; installed for Xcode.
- Still needed for an App Store build: profiles for the Watch app
  (`com.agraabhi.oshodiscourses.watchkitapp`) and, for the Mac, a Mac Catalyst one.

The live form asked only for App Type and agreement; name, email and organization
were prefilled from the account. The answers below were prepared in case Apple
follows up asking about the app.

| Field | Answer |
| --- | --- |
| App type | Audio |
| App name | Osho Talks |
| Bundle ID | `com.agraabhi.oshodiscourses` |
| App Store link | <https://apps.apple.com/app/id6774409039> |
| Requested entitlement | `com.apple.developer.carplay-audio` |

**Description of the CarPlay experience**

Osho Talks plays recorded spoken-word discourses (English and Hindi) that the
listener has downloaded on iPhone. In CarPlay it shows three lists: Continue
Listening, Downloads (by series) and Bookmarks. Choosing a row plays it in the
shared Now Playing screen, which adds a playback-speed button and a button that
saves a bookmark at the current time. Up Next shows the rest of the series.
Everything plays from local files; there is no video, text reading, sign-in or
purchase in the car. The app uses the standard list and Now Playing templates
only.

After approval: enable the capability on the App ID, refresh the provisioning
profiles, and archive with the `OshoDiscoursesCarPlay` scheme (`Release-CarPlay`),
which signs with `Signing/CarPlay.entitlements`. Then complete the head-unit
checks in [CarPlay](../../carplay.md#device-acceptance).
