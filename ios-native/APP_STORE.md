# App Store

What to enter in App Store Connect, and what is left before the first submission.

## Listing

- **Name:** Ilyich
- **Subtitle:** Self-hosted photo library
- **Category:** Photo & Video. **Price:** free. **Age rating:** answer None to every question (4+).
- **Devices:** iPhone only; iPads run it as an iPhone app, so no iPad screenshots are needed.
- **Keywords:** `photos,backup,self-hosted,gallery,video,albums,memories,private,library,server,offline,home,nas`. Leave out other apps' names; App Review rejects trademarks in keywords.
- **Support URL:** https://github.com/ilyador/Ilyich/issues
- **Privacy policy URL:** https://github.com/ilyador/Ilyich/blob/dev/ios-native/PRIVACY.md
- **Copyright:** 2026 Ilya Dorman
- **What's New:** First release.

### Description

The description is the only place the app names Immich.

```text
Ilyich is a fast, native iPhone app for the photo library you host yourself. Your photos and videos stay on your own server, and Ilyich keeps a copy of the library on your phone so you can browse it anywhere, even offline.

• Scroll through tens of thousands of photos without waiting
• Back up this iPhone's photos and videos automatically
• Albums, shared albums and partner sharing
• People, places on a 3D globe, and On this day memories
• Search by what's in a photo, or by file name, place, camera and date
• Favorites, archive, trash, duplicates, and a Locked Folder with Face ID
• Crop, rotate and flip without touching the original
• Free up space on your phone once photos are backed up

Ilyich works with Immich servers, version 3.3.0 or later. Its own server, an open-source fork you can run instead, adds previews developed from your Lightroom edits and a natural-language search that double-checks its results: github.com/ilyador/Ilyich

Ilyich is open source under the GNU AGPL v3. It is an independent project, not affiliated with or endorsed by Immich.
```

## App Review notes

```text
Ilyich is a client for a self-hosted photo server and shows nothing until it signs in to one. Demo account:
Server URL: <server URL>
Email: <email>
Password: <password>
Locked Folder PIN: <PIN>

The demo account holds sample photos. Backups and edits made while reviewing go to that account only.

- The app connects only to the server address the user enters. NSAllowsArbitraryLoads is on because self-hosted servers often run on a home network over plain HTTP, at an address we can't know in advance.
- Location is asked for only when the user sets a photo's location from where they are, or asks the app to read the Wi-Fi name (iOS requires location permission for it) to use the server's home address.
- Local network access reaches a server on the home network.
```

## App Privacy

- **Data collection:** "No, we do not collect data from this app." The app has no analytics, ads or third-party SDKs.
- Photos, account details and searches are not "collected" in Apple's sense: they go only to the user's own server, which the developer can't reach.

## Compliance already in the app

- **Export compliance:** Info.plist sets `ITSAppUsesNonExemptEncryption` to NO (HTTPS only), so App Store Connect doesn't ask.
- **Privacy manifests:** `Config/PrivacyInfo.xcprivacy` and `Extensions/Share/PrivacyInfo.xcprivacy` declare the required-reason APIs.
- **Content rights:** answer No. The app shows the user's own photos; the map data is Natural Earth's public domain data, credited under About.
- **Licenses:** the app ships your code and ThumbHash (MIT, credited under About > Licenses). Nothing outside `ios-native` is compiled in.
- **Bundle ID:** `io.ilyador.ilyich`, App Group `group.io.ilyador.ilyich`. Users never see it, and it can't change after the first upload.

## Left before submitting

1. Fill the review notes from the demo server's credentials file (`/mnt/data/ilyich-demo/credentials.json` on the home server): its address, the reviewer's email and password, and the Locked Folder PIN. The server holds about 300 Pexels photos and videos in 14 shoots with albums, places, named people, a partner and a shared album. Keep the address out of this public repo.
2. The App Store Connect record, with the bundle ID above. Team H4K2MSF2SG is already in the paid Apple Developer Program.
3. Screenshots for the 6.9-inch iPhone (1320 × 2868), at least three. iPhone 15 Pro screenshots are too small.
4. Archive and upload: Xcode's Organizer, or `xcodebuild archive` and `-exportArchive` on the Mac with an App Store Connect API key.
