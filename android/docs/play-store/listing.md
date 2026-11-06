# Google Play store listing

Text for **Grow users > Store presence > Main store listing** (en-US). It follows
the iOS listing in `docs/app-store/metadata/`, without Apple-only features
(Listen in Translation, Apple Watch, iPad, CarPlay, AirPlay, Files app).
Play forbids "free", "best" or ranking claims in the title and short description.

| Field | Value |
| --- | --- |
| App name (30) | Osho Talks - Audio Discourses |
| Short description (80) | Osho's English and Hindi discourses, with transcripts and offline listening. |
| App icon | [`icon-512.png`](icon-512.png), 512 × 512, from the iOS app icon |
| Feature graphic | [`feature-graphic.png`](feature-graphic.png), 1024 × 500 |
| Phone screenshots | 2 to 8, taken on a phone (to do) |
| Category | Music & Audio |
| Tags | Podcasts, Audiobooks, Meditation |
| Privacy policy | `https://github.com/aagrawal207/OshoDiscourses/blob/main/android/PRIVACY.md` |
| Website | `https://github.com/aagrawal207/OshoDiscourses` |

## Full description (4000)

```text
Listen to Osho in English and Hindi, with 5,481 discourses across 351 series. Download a talk for a walk or a quiet evening, read along with its transcript, and continue from your saved position next time. Every feature is free.

READ AS YOU LISTEN
Original-language transcripts are available for 4,946 discourses. Follow highlighted text, search for a passage, change the text size, or tap a sentence to play from that point. Copy or share one passage or several, or pick out exact words. The reader remembers your place, and Audio is here lets you correct timing when needed.

FIND YOUR NEXT DISCOURSE
Explore Zen, Tantra, Tao, Upanishads, Yoga and more. Search by series name or topic, filter by language, or start with Popular and Beginner Friendly collections.

LISTEN OFFLINE
Download talks by series and see how much storage they use. Downloads continue when you switch apps or lock the screen. Optional Smart Download prepares the next discourse, while Smart Delete can clear finished recordings.

ADJUST THE SOUND
DeNoise brings recording cleanup, volume boost and quiet-speech controls together. Choose Best Quality, Balanced or Gentle Cleanup and compare with the original sound. Results vary by recording.

SAVE A MOMENT
Add timestamped bookmarks with notes and categories, then return directly to a passage. Listening stats show daily totals, streaks and completed discourses. Set a sleep timer for a countdown or the end of a talk.

MADE FOR EVERYDAY LISTENING
- Background playback with lock screen, notification and headphone controls
- Playback speed from 0.5x to 2x in fine steps such as 0.85x, with quick back and forward controls
- Optional sync of progress, bookmarks, listening stats and transcript reading state through a private app folder in your own Google Drive
- Light, dark or system appearance and eight accent colours

No app account is required. There are no ads or tracking. Optional one-time tips and auto-renewing yearly support through Google Play help fund development. Neither unlocks features or content; every feature stays free. Manage or cancel yearly support in Google Play > Payments and subscriptions.

Privacy Policy: https://github.com/aagrawal207/OshoDiscourses/blob/main/android/PRIVACY.md

Osho Talks is an independent app. It is not affiliated with or endorsed by Osho International Foundation, Osho World Foundation or any other Osho organisation. Audio and transcripts are accessed from publicly available sources.
```

## App content answers

Draft answers for **Policy and programs > App content**. Check each against the
form's current wording before submitting.

| Form | Answer |
| --- | --- |
| Privacy policy | The URL above |
| Ads | No ads |
| App access | All functionality is available without special access (Drive sync uses the listener's own Google account; there is no app login) |
| Content rating | IARC questionnaire, category "All Other App Types". No violence, sexual content, profanity, drugs or gambling; no user-to-user communication or location sharing. The app offers in-app purchases (tips and yearly support) |
| Target audience | 18 and over (some talks discuss adult themes); not designed for children |
| News app | No |
| Government app | No |
| Financial features | None |
| Health | None |
| Data safety | See below |
| Foreground services | `mediaPlayback`: plays the talk the listener started while the screen is off or another app is open. `dataSync`: downloads talks the listener chose. Each needs a short screen recording link |

### Data safety

The developer receives no data. Google's form still counts data the app sends
off the device, so the optional Drive sync is declared.

| Question | Answer |
| --- | --- |
| Collects or shares required data types | Yes (only through optional Drive sync) |
| Encrypted in transit | Yes (HTTPS) |
| Users can request deletion | Yes: Settings > Sync, and Google Drive > Manage apps > Delete hidden app data |
| App activity > App interactions | Collected, optional, not shared. Purpose: app functionality (listening positions, history, stats) |
| App activity > Other user-generated content | Collected, optional, not shared. Purpose: app functionality (bookmark notes) |
| Financial info, location, personal info, contacts, files, audio, device IDs | Not collected. Tip order IDs stay on the device; Google Play handles payment |
