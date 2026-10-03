# Tip jar App Store Connect assets

App: **Osho Talks - Audio Discourses**, `6774409039`.
Bundle ID: `com.agraabhi.oshodiscourses`.

The five consumables were created on 2026-09-16. Readback confirmed
`READY_TO_SUBMIT` for each product, with English (`en-US`) metadata, review notes,
and a completed review screenshot upload.

All five were resubmitted with **1.15.0 (26)** on 2026-09-18 in review submission
`a04b9660-b31f-4ff8-9e83-4958e34417d6`. On 2026-09-19, readback confirmed every
product is `APPROVED`, the app is `READY_FOR_DISTRIBUTION`, and the submission is
`COMPLETE`. The resubmission followed build 25's rejection under Guidelines
2.1(b) and 1.5 and included the updated Support URL and a physical-device
walkthrough with a successful Small tip sandbox purchase. See the
[release record](../releases/1.15.0.md).

| Name | Product ID | App Store Connect ID | US base price |
| --- | --- | --- | ---: |
| Small tip | `com.agraabhi.oshodiscourses.tip.small` | `6812952691` | $3.00 |
| Generous tip | `com.agraabhi.oshodiscourses.tip.medium` | `6812952817` | $5.00 |
| Big tip | `com.agraabhi.oshodiscourses.tip.large` | `6812953154` | $10.00 |
| Grand tip | `com.agraabhi.oshodiscourses.tip.grand` | `6812953066` | $25.00 |
| Patron tip | `com.agraabhi.oshodiscourses.tip.patron` | `6812953032` | $50.00 |

Names and descriptions match
[`TipJar.storekit`](../../../OshoDiscourses/TipJar.storekit). Each product uses
the USA as its pricing base, with 174 Apple-generated regional prices. Availability
matches all 175 app storefronts and includes new territories automatically.

## Review assets

- [`review-notes.txt`](review-notes.txt) explains the optional, repeatable tips,
  their lack of entitlements, and Settings > About > Support Development.
- [`support-development.png`](support-development.png) shows all five tiers in
  the production tip-jar view. It was captured on iPhone 17 Pro / iOS 26.5 through
  Xcode's local StoreKit configuration, then exported as 1206 × 2622 RGB PNG
  without an alpha channel.
- Every upload completed with the source checksum
  `ebca3944ebbdcca29bd2275ebd5119e0`, matching the local screenshot.

| Tier | IAP version ID | Localization ID | Review screenshot ID |
| --- | --- | --- | --- |
| Small | `8cfbcadf-0d88-4d9c-99c9-c998d1f41e59` | `8b345e06-1530-44ae-b913-11588b931e03` | `d271e2a2-75a6-4255-98eb-e7d5a48aee89` |
| Generous | `eb28e203-d64c-46e9-a909-67c455db3a13` | `9d59325d-9f52-406f-84f3-61f2c204a661` | `56c38329-edd7-4cfd-bbce-303ec9add4d5` |
| Big | `7b3a1c6c-2b8d-4988-9613-5e2322c2ab7b` | `f501fb3f-aaf3-46d2-b5ff-de23c559e05c` | `3ea934aa-2297-49cb-9f8e-f2fc3a0ecda2` |
| Grand | `3f7c42db-44de-46be-a87c-e0854b4d94e3` | `787a7347-3024-4706-bab6-d889b655fb7c` | `1dde4db0-3d1f-4aa7-a084-dfbe4f7d9378` |
| Patron | `d4822165-1a79-4107-9451-c81b62467c0c` | `ced49816-57c7-4b10-9cf3-f26fcad7203d` | `48fadc39-1732-4937-a8c8-7b0c65ca5b89` |

The older `OshoDonations` / `buymeacoffee` non-consumable (`6809799061`) is an
incomplete legacy draft. The app's tip service uses only the five IDs above.

## Verification and submission

```bash
asc iap list --app 6774409039 --type CONSUMABLE --include-versions --output table
asc iap pricing summary --app 6774409039 --output table
asc validate iap --app 6774409039
```

`asc validate iap` reports ready-to-submit products as warnings until submitted;
it also includes the incomplete legacy draft. Product details, localization text,
all 175 available territories, 174 automatic prices and screenshot checksums were
read back from Apple after creation.

For individual regional amounts, use Apple's `automaticPrices` relationship with
`include=inAppPurchasePricePoint,territory`. The installed CLI's `--resolved`
output mixed up some price points that share a numeric ID across territories;
direct API reads confirmed the actual regional prices.

Local StoreKit product discovery and the five-tier presentation were verified.
The attached 60.66-second physical-device walkthrough starts on the iPhone Home
Screen, launches the app and demonstrates core features. It shows all five prices,
a successful US$3 Small tip sandbox purchase and the in-app count increasing from
two to three. It replaces the earlier purchase-only clip; see the
[release record](../releases/1.15.0.md#purchase-recording).
The five tips are included in the 1.15.0 resubmission.
