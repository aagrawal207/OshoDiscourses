# Google Play products

The Play Console setup for Osho Talks' optional tips and yearly support. It
matches the iOS products in [`docs/annual-support.md`](../../docs/annual-support.md)
and the root `CLAUDE.md` tip jar table. Nothing here unlocks features or
content. Every feature stays free.

Package name: `com.agraabhi.oshodiscourses`. The code lives in `:billing`
(`PlaySupportStore`, `SupportProducts`).

## Product IDs

The app uses the iOS product IDs internally. Tips keep the same IDs on Play.
Play limits subscription IDs to 40 characters, and the iOS yearly IDs are 43 or
44 characters, so the Play IDs drop the `com.agraabhi.` prefix.
`SupportProducts.annualPlayIDs` maps them, and the UI never sees a Play ID.

| iOS ID (app contract) | Play product ID |
| --- | --- |
| `com.agraabhi.oshodiscourses.tip.small` | `com.agraabhi.oshodiscourses.tip.small` |
| `com.agraabhi.oshodiscourses.tip.medium` | `com.agraabhi.oshodiscourses.tip.medium` |
| `com.agraabhi.oshodiscourses.tip.large` | `com.agraabhi.oshodiscourses.tip.large` |
| `com.agraabhi.oshodiscourses.tip.grand` | `com.agraabhi.oshodiscourses.tip.grand` |
| `com.agraabhi.oshodiscourses.tip.patron` | `com.agraabhi.oshodiscourses.tip.patron` |
| `com.agraabhi.oshodiscourses.support.annual5` | `oshodiscourses.support.annual5` |
| `com.agraabhi.oshodiscourses.support.annual10` | `oshodiscourses.support.annual10` |
| `com.agraabhi.oshodiscourses.support.annual15` | `oshodiscourses.support.annual15` |

Play never lets you reuse or rename a product ID, even after you delete the
product. Copy the IDs exactly.

## Prices

USD prices are the iOS US base prices. INR prices are the India App Store
prices for the same products, read from the public India listing on
2026-10-17. Set both by hand in Play Console. Let Play convert the remaining
countries from the USD price, then review the rounding.

## One-time products (tips)

Create these under **Monetize with Play > Products > One-time products**. Each
has one **Buy** purchase option. Turn on **Backwards compatible**, and keep
multi-quantity **off**: the app counts one tip per order. The app consumes each
tip after it records it, so the same tip can be bought again.

| Product ID | Name | Description | USD | INR |
| --- | --- | --- | ---: | ---: |
| `com.agraabhi.oshodiscourses.tip.small` | Small tip | A coffee for the developer. | 3.00 | 299 |
| `com.agraabhi.oshodiscourses.tip.medium` | Generous tip | Covers a month of the odd fix. | 5.00 | 499 |
| `com.agraabhi.oshodiscourses.tip.large` | Big tip | Funds an afternoon on a new feature. | 10.00 | 999 |
| `com.agraabhi.oshodiscourses.tip.grand` | Grand tip | You are keeping this app alive. | 25.00 | 2,499 |
| `com.agraabhi.oshodiscourses.tip.patron` | Patron tip | Helps fund more improvements to the app. | 50.00 | 4,999 |

Use the purchase option ID `buy` for each tip. Make every product available in
all the app's countries, and turn on availability in new countries.

## Subscriptions (yearly support)

Create these under **Monetize with Play > Products > Subscriptions**. iOS keeps
the three tiers in one subscription group. Play has no groups, so the app blocks
a second subscription itself: any current, grace-period, on-hold or paused
subscription disables new yearly purchases.

| Product ID | Name | Description | USD / year | INR / year |
| --- | --- | --- | ---: | ---: |
| `oshodiscourses.support.annual5` | Small yearly support | Optional support for ongoing app development. | 5.00 | 499 |
| `oshodiscourses.support.annual10` | Generous yearly support | Optional support for ongoing app development. | 10.00 | 999 |
| `oshodiscourses.support.annual15` | Extra yearly support | Optional support for ongoing app development. | 15.00 | 1,499 |

Give each subscription one base plan with these settings:

| Setting | Value |
| --- | --- |
| Base plan ID | `yearly` (the app looks for this ID) |
| Type | Auto-renewing |
| Billing period | 1 year |
| Grace period | Play default |
| Account hold | Play default (the app treats it like iOS billing retry) |
| Resubscribe | On |
| Offers | None: no free trial and no introductory price |

For each subscription, add one benefit: "Supports ongoing app development".
Activate the base plan. The app hides a subscription whose base plan is not
active or not yearly, and shows "Some yearly support options aren't available
right now."

## License key

Copy the Base64 RSA public key from **Monetize with Play > Monetization setup >
Licensing**. `:app` passes it to `PlaySupportStore(licenseKey = ...)`. Keep it
in a Gradle property or `local.properties` and expose it through `BuildConfig`.
The key is public, but it must match this app. When the key is absent, the app
does not check purchase signatures. Debug builds can run without the key;
release builds must include it.

## License testers

1. In Play Console, open **Settings > License testing** (account level, not app
   level).
2. Add the Google accounts that will test. Use a Google Group for a team.
3. Set **License response** to `RESPOND_NORMALLY`.
4. Testers see test payment methods in the purchase sheet and are never
   charged:
   - **Test card, always approves**: a normal purchase.
   - **Test card, always declines**: a failed payment.
   - **Slow test card, approves after a few minutes**: a pending purchase that
     completes later.
   - **Slow test card, declines after a few minutes**: a pending purchase that
     Play cancels.
5. License tester subscriptions renew quickly. A yearly plan renews every 30
   minutes and ends after six renewals.

## Internal testing track

Play Billing only returns products for an app that Play knows. Upload a build
first.

1. Build a signed release bundle with the same application ID:
   `./gradlew :app:bundleRelease`.
2. In Play Console, open **Test and release > Testing > Internal testing**.
   Create a release with the bundle and roll it out.
3. Add the license testers to the internal testers list. Open the opt-in link
   with each tester account and accept.
4. Create and activate the products above. New products can take a few hours
   to appear in the app.

## Test on the emulator

Use an emulator with the Play Store, not plain Google APIs.

1. In Android Studio Device Manager, create a phone with a **Google Play**
   system image (API 34 or later). Pixel devices marked with the Play Store
   icon have it.
2. Start it, open the Play Store and sign in with a license tester account.
3. Open the internal testing opt-in link in Chrome on the emulator. Install Osho
   Talks from the Play Store.
4. A sideloaded debug build with the same application ID can also reach
   billing for a license tester. If it shows "Couldn't load tips from Google
   Play", install from the opt-in link instead.
5. Open Settings > About > Support Development.

Check these cases:

| Case | Steps | Expected |
| --- | --- | --- |
| Catalog | Open the support sheet | Five tips and three yearly plans, ordered by price, with Play's local prices |
| Tip | Buy Small tip with the always-approves card | Thank-you message; the tip count goes up by one; buy it again and the count goes up again |
| Declined tip | Buy with the always-declines card | A failure message; no count change |
| Pending tip | Buy with the slow approving card, close the sheet, wait | Pending message, then the count goes up once Play approves it |
| Cancelled pending tip | Buy with the slow declining card | Pending message, then no count change |
| Yearly | Buy Small yearly support | Thank-you message; all yearly buttons are disabled |
| Renewal | Wait 30 minutes with the app open, then return to it | Still current, with no new thank-you message |
| Cancel | Cancel in Play Store > Payments and subscriptions; wait for expiry | Yearly buttons become available again after the paid period |
| Restore | Uninstall, reinstall and tap Restore | "Your yearly support subscription is restored. Thank you." |
| Pending yearly | Buy with the slow approving card | Other amounts stay disabled until Play approves or cancels the request |

`:app` must call `PlaySupportStore.recoverPurchases()` when the app returns to
the foreground. Play has no renewal stream, so this call picks up renewals,
cancellations and approvals that happened while the app was in the background.

## In-app review

Play decides whether the review card appears, and quota limits apply. To see the
card, install the app from internal app sharing. The card shows there, but its
submit button is disabled. A license tester who already reviewed the app may not
see the card. The rating link in Settings > About opens the app's Play Store
page.
