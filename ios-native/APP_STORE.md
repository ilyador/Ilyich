# Ilyich App Store submission

Draft for owner review. **Not submitted for review or released.** The previously uploaded 3.3.5 (3040108) build predates paid access; both phones have development build 3040107.

**Replacement build:** 3.3.5 (3040109), with paid access, was uploaded to App Store Connect on 2026-11-12. Select it in the draft once Apple finishes processing. Do not submit build 3040108.

[App Store Connect draft](https://appstoreconnect.apple.com/apps/6833595725/distribution/ios/version/inflight) · App ID **6833595725**

## Listing fields

| Field | Text |
|---|---|
| Name | Ilyich |
| Developer | Simplicity Binary, unipessoal, lda |
| Subtitle | Your self-hosted photo library |
| Category | Photo & Video |
| Price | Free download; subscription or lifetime purchase for full access |
| Primary language | English |
| Devices | iPhone, iOS 27 or later |
| Age rating | 4+ (Apple-calculated; no Kids designation) |
| Support URL | https://github.com/ilyador/Ilyich/issues |
| Privacy policy | https://github.com/ilyador/Ilyich/blob/dev/ios-native/PRIVACY.md |
| Copyright | 2026 Ilya Dorman |
| Release | Manual release after approval |

## Pricing

Owner-selected pricing matches [Stream](https://apps.apple.com/pt/app/stream-achar-fotos/id6475726557). Portugal is the base storefront; Apple calculates other currencies.

| Full app access | Price | Trial |
|---|---|---|
| Monthly subscription | €1.99/month | One week for eligible new subscribers |
| Annual subscription | €14.99/year | One week for eligible new subscribers |
| Lifetime purchase | €39.99 once | No recurring subscription or introductory trial |

Monthly and annual plans share one subscription group and one introductory-trial eligibility. Purchases belong to the Apple account, independently of the photo-server account. Lifetime does not automatically cancel an existing subscription.

**Promotional text**

Browse your photo server from iPhone. Back up new photos, organize albums, revisit memories, and find a picture by person, place or date.

**Keywords**

`backup,selfhosted,albums,gallery,memories,server,nas,places,offline,favorites`

## Description

```text
Ilyich brings the photo and video library on your own server to your iPhone. Sign in with your server address and account to browse, organize and back up your pictures.

• Browse your timeline and jump to a month.
• Automatically back up selected iPhone albums to your server.
• Open albums and shared albums, and browse photos shared by partners.
• Find pictures by person, place, date, camera, filename or text inside a photo.
• Revisit On This Day memories and explore photo locations on a globe.
• Keep favorites, archive photos and manage your trash.
• Unlock your Locked Folder with Face ID.
• Crop, rotate and flip photos while keeping the originals.
• Review verified backups before freeing space in Apple Photos.

Saved library details and cached images remain available without a connection. Full-size photos, videos and searches may need your server. iOS controls when background backups can run.

Ilyich connects to compatible Immich and Ilyich servers. The open-source Ilyich backend adds previews from supported Lightroom adjustments and optional AI checking for photo-content searches. These features depend on server configuration.

A compatible server and an existing account are required. The app does not include photo hosting.

Full access requires a monthly or annual subscription, or a one-time lifetime purchase. Eligible new subscribers can try the app free for one week. Subscriptions renew automatically unless cancelled; manage or cancel them in your App Store account settings. Prices are shown before purchase.

Source code and server: https://github.com/ilyador/Ilyich

Ilyich is an independent project, not affiliated with or endorsed by Immich. Open source under the GNU AGPL v3.

Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

**What’s New**

First App Store release.

## Private App Review notes

The private review copy contains the dedicated demo credentials. Never put them in this repository or the public description.

```text
Ilyich is an iPhone client for a self-hosted photo server. Sign-in is required.

Full app access also requires an Apple in-app purchase. Monthly and annual subscriptions offer a one-week introductory trial to eligible accounts; lifetime access is a one-time purchase. Test these through Apple's App Review purchase environment, then use the sample server account below. Restore Purchases and subscription management remain accessible on the access screen. Purchases do not include hosting or change server accounts.

Server address: <REVIEW_SERVER>
Email: <REVIEW_EMAIL>
Password: <REVIEW_PASSWORD>
Locked Folder PIN: <REVIEW_PIN>

Accounts belong to the connected server, whose administrator controls provisioning and deletion. The app does not include photo hosting or public registration. SSO, when available, uses that server’s configured identity provider.

Use this reviewer account rather than the server administrator account. It contains 255 sample photos and videos and 13 albums. Photos permission is not needed to browse this sample library. Please use sample content for any uploads to this shared review account.

Swipe inward from the left edge to open People, Albums, More and Settings. Swipe inward from the right edge to navigate the timeline. Long-press a photo to start selection. Manage people opens the full People page.

Photos permission supports local photos, selected-album backup and saving downloads. Settings > Backup contains Automatic backup and the iCloud-original download option. iOS controls background scheduling.

Free up space offers local photos only after checking their backups on the signed-in server. Remote sample photos alone are not eligible. Apple Photos asks for confirmation before local removal.

AI check is optional and off by default. Enable it in photo-content search. Our review server uses a locally hosted verifier. Other features depend on the connected server.

The app accepts user-supplied server addresses, including HTTP addresses on home networks. Local network access supports these servers. Optional location permission supports choosing a photo location and Wi-Fi-based server routing. Maps and place search use Apple Maps.

Privacy policy and support contacts are in Settings > About.
```

## Readiness and remaining review

- **Saved in Apple:** listing, review login/contact, category, content rights, age rating, free pricing in 175 regions and manual release. Mac and Vision Pro availability are off.
- **Screenshots:** all eight uploaded in order at 1284 × 2778. Apple uses these assets for the required display group. Submission copies are in `~/Downloads/ilyich-screenshots/AppStore/`; originals are preserved.
- **Build:** 3.3.5 (3040109) was exported with Apple Distribution signing and uploaded on 2026-11-12 (Xcode reported `Upload succeeded`). Selecting it in the submission draft is pending App Store Connect sign-in. 3040108 remains in TestFlight, unselected; do not submit it.
- **Validation:** 226 checks pass: 20 purchase-policy tests, 202 account/transfer/library/cleanup regressions, three normal purchase UI tests, and one accelerated natural-expiry UI test. The accelerated test runs separately after the normal purchase UI tests because they share StoreKit's clock. Earlier backend checks and the attended Photos cleanup test remain valid.
- **Purchases:** all three product records and Portugal prices are saved. Monthly/annual one-week trials cover 175 storefronts with no offer end date. Both subscriptions share level 1 under Ilyich Access. English product/group copy and review notes are saved. Three genuine 1284 × 2778 paywall review screenshots are prepared and visually verified; uploading them to the product Review screenshot slots and save/reload verification are pending because App Store Connect currently redirects to a failed login. No review submission was made. The Paid Apps agreement is signed but shows **Pending User Info**. Both US tax forms are **Active**; no payout bank account is listed yet.
- **Privacy draft saved:** “Data Not Collected” for the distributed client: users choose their own server; no developer backend, tracking, ads or analytics is built in. The private App Review server is a sample-content test fixture. Offering it as consumer hosting would require reassessing the label. Publish the reviewed label and updated `PRIVACY.md` / `SUPPORT.md` before submission; the public policy currently has older wording.
- **Accounts:** existing server accounts and SSO remain supported. Servers manage provisioning and deletion; some provision on first SSO login. Review notes explain this model. Apple’s account-deletion applicability may need clarification during review.
- **EU distribution:** email and phone verified; trader declaration saved and reload-verified as **Active** for all 27 EU regions.
- **Contact disclosure:** GitHub Issues is the public support channel. Keep direct contacts only in Apple's required private App Review fields and mandatory EU trader details; omit them from promotional copy, the app UI and public support/privacy text.
- **Owner review:** approve the listing, review notes and policy text before submission. Release remains manual.

## Apple references checked

[Support/contact and privacy requirements](https://developer.apple.com/app-store/review/guidelines/), [App Privacy definitions](https://developer.apple.com/app-store/app-privacy-details/), [account deletion](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion), [metadata fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information).
