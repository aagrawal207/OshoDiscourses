# Crash: `_setSheetConfiguration:` on `_UISceneHostingController`

## Reports

Two App Store crashes in 1.17.0 (36), one crash group in Xcode Organizer. No
other version has this crash.

| Date | Device | iOS | Time after launch |
| --- | --- | --- | --- |
| 2026-10-20 | iPhone 11 (`iPhone12,1`) | 27.0.1 | 11 min |
| 2026-10-23 | iPhone 13 (`iPhone14,5`) | 26.7.1 | 100 s |

Both are `NSInvalidArgumentException`:
`-[_UISceneHostingController _setSheetConfiguration:]: unrecognized selector`.
Every frame is UIKit sheet code
(`-[UISheetPresentationController _tryToConnectToRemoteSheet:]` from
`presentationTransitionWillBegin`). No app frame appears except `main`.

## What UIKit does

When a sheet starts presenting, `_expectedRemoteSheet` looks in the presented
controller for content that runs in another process and passes it to
`_tryToConnectToRemoteSheet:`, which sends it `_setSheetConfiguration:`. The
correct object is `_UISceneHostingSheetPresentationHostComponent`. In the iOS 27
runtime, `-[_EXHostViewControllerSession remoteSheet]` returns its
`_hostingController` (a `_UISceneHostingController`) when set, and that class
does not implement the selector. So the crash needs an ExtensionKit-hosted sheet
whose remote sheet resolves through that path.

## Device evidence

On iOS 27.0.1 (iPhone 16 Pro), Apple's language download prompt from
`prepareTranslation()` is a SwiftUI form sheet containing
`EXHostViewController` > `_UISceneHostingViewController`. It is presented from
the root `ContentView` controller, because `NarrationPreparationHost` (and its
`.translationTask`) sits in the root's background:

1. The root dismisses the open Listen in Translation sheet.
2. The root presents Apple's prompt while that sheet is still disappearing.
3. Closing the prompt marks the run interrupted, and the narration sheet is
   presented again from the root.

UIKit calls `_tryToConnectToRemoteSheet:` several times during these swaps. In
the observed runs it received `nil` or the correct host component, so it did not
crash. The raw log and both crash reports are in `build/crash-2026-10/`
(untracked).

The share sheet does not reach this code on iOS 27. Manage Subscriptions shipped
in 1.16.3 with no crashes. The language prompt is the only ExtensionKit sheet new
in 1.17.0.

## Status

Not reproduced. The likely trigger is Apple's language prompt presented at the
root while another root sheet is still animating. Fixed for 1.17.1: consent is
requested only from the visible Listen in Translation sheet
(`NarrationConsentTaskHost`), so the prompt stacks on it, and automatic continue
never shows the prompt. Generation already uses an installed-language session
with no UI.

Simulator runtimes cannot show the language prompt. With "On-Device Translation:
Automatic", `LanguageAvailability()` reports languages as installed when they are
not downloaded. Only the standard (`.lowLatency`) strategy shows the prompt.
