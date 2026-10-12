# Optional yearly support

The requested $5, $10 and $15 annual subscriptions sit among the existing one-time
tips, ordered by the App Store's localized price. Equal-priced one-time tips come
first. Every row identifies its billing frequency. No feature or recording is
paywalled, and existing tip product IDs and transaction history are unchanged.

The three subscriptions share group `22466252` (Optional Yearly Support), all at
level 1. An existing subscription, grace period or billing retry disables new
annual purchases and directs the listener to Apple's management sheet instead.
Cancellation leaves the plan current through its paid period. Restore uses
`AppStore.sync()`. Subscription state comes from verified StoreKit status, not a
local donor flag. Verification or status failures block annual purchases, but do
not remove access to the app or the existing tip options.

Pending annual requests remain blocked after the information banner is dismissed
and across app relaunches. Approval clears the pending marker. A declined or
cancelled request can be cleared explicitly after a warning; the app does not
assume that an absent entitlement means a pending request was declined.

| Product ID suffix | US annual price | App Store Connect ID | Review version ID |
| --- | ---: | --- | --- |
| `support.annual5` | $5.00 | `6821753721` | `c4f1a1e4-181a-44ae-aab2-043cec76ba35` |
| `support.annual10` | $10.00 | `6821753662` | `df8cbc47-c31a-4f7a-966b-7cdc993e7d59` |
| `support.annual15` | $15.00 | `6821753750` | `d2ad6399-d6a3-4196-9dfe-f0aa1276e18f` |

All IDs begin with `com.agraabhi.oshodiscourses.`. Draft products use one-year
periods, the app's existing 175 territories, automatic future-territory availability
and Apple-equalized regional prices. They were submitted with 1.16.3 (33) and are
awaiting review. Product approval is still required. Apple guideline 3.1.2(a) requires ongoing
customer value; acceptance of optional development-support subscriptions is not
guaranteed. Review notes explain that these support ongoing app development and
do not sell access to the recordings.

Setup and pricing were read back on 2026-10-11. The group review version is
`9d2842e3-b25f-4747-a9c8-1cffe4ac5fcf`, with an en-US “Yearly Support” localization.
All three products have complete review screenshots. The app version, group
version and three subscription versions are in submission
`0c1b46f3-c078-43bd-b1b2-0bfd0c43cde6`, whose state is `WAITING_FOR_REVIEW`.

## Metrics

The app's existing convention is local OSLog, not remote analytics. These events
use category `AnnualSupport`, with bounded operation/outcome values and no account,
transaction or customer IDs.

| Metric/event | Emitted when | Dimensions | Why |
| --- | --- | --- | --- |
| Product load | Each load finishes | available, partial, failed | Diagnose unavailable products |
| Status refresh | Each status read finishes | verified, failed | Diagnose verification and account errors |
| Purchase | Attempt is blocked or completes | blocked, completed, pending, cancelled, failed | Distinguish purchase outcomes |
| Transaction | Verified transaction finishes, or verification/type fails | finished, unverified_or_unsupported | Diagnose transaction handling |
| Restore | Restore finishes or fails | completed, cancelled, failed | Diagnose account recovery |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Product ID/type allowlist; no overlap with tips | Product validation | Unit |
| Active, grace and billing-retry plans block duplicate purchases | Status policy | Unit |
| Expired/revoked plan permits new support | Status policy | Unit |
| Future product in the same group blocks duplicates | Forward compatibility | Unit |
| Status error blocks purchase, successful retry recovers | Failure/retry | Unit |
| Overlapping status requests wait for the refreshed snapshot | Concurrency | Unit |
| Missing products and load failure | Product discovery | Unit |
| Busy, pending, cancelled and failed purchases | Purchase lifecycle | Unit |
| Pending banner dismissal and relaunch do not allow another annual request | Purchase safety | Unit |
| Verified, unverified, wrong-product and refunded transactions | Verification/finish | Unit |
| Renewal/refund updates never trigger unsolicited thank-you alerts | Background lifecycle | Unit |
| Restore finds a plan, finds none, is cancelled or fails | Restore lifecycle | Unit |
| Exact prices, yearly periods, one group and interleaved order | Local StoreKit catalog | Integration |
| Native purchase, renewal, cancellation, expiry and relaunch | Local StoreKit transactions | Integration |
| Native restore and refund | Local StoreKit transactions | Integration |

OSLog emissions are manually inspectable, not asserted by a mock logger. Local
StoreKit tests do not prove TestFlight product discovery, production billing,
cross-device account behavior or App Review approval. Those remain release gates.

## Engagement

The native rating request follows three distinct listening days and a natural
stop or manual pause after twenty minutes of listening that day. It is limited to
once per app version and once per ninety days. Support and rating requests have
at least fourteen days between them.

The inline Home support card requires seven listening days and two hours of total
listening. It stays hidden during playback, sleep timers, player presentations and
background use. A one-time tip or a current annual subscription suppresses it;
unknown subscription status also keeps it hidden. Only one window can own the
card. Its ninety-day cooldown starts when at least half the card is visible,
rather than merely when Home is constructed.

“Not Now” hides support reminders for ninety days. “Don't Ask Again” opts out
permanently on this device. No rewards or sentiment screening are used for
ratings. `EngagementServiceTests` and `ReviewRequestServiceTests` cover eligibility,
boundaries, persistence and cross-window coordination; `EngagementPresentationTests`
exercise the Home actions and playback suppression.

Support sheets opened from Settings also suppress rating requests in other
windows. Dismissing one sheet does not release another window's suppression.

The local OSLog `Engagement` category records bounded support outcomes
(`shown`, `opened`, `snoozed`, `opted_out`) and rating-attempt outcomes
(`requested`, `suppressed`). No customer identifiers or remote telemetry are added.
