# Ilyich privacy policy

Last updated November 11, 2026.

Ilyich connects to a photo server that you run or choose yourself. It has no ads, analytics or tracking, and includes no third-party SDKs.

## Where your data goes

- Account requests, uploads, searches, albums and edits go to the server you sign in to. Its administrator controls access, processing, retention and backups. The developer does not receive this data unless you choose a server the developer operates.
- The developer operates a separate review demo. Its administrators can access data sent to it. Use sample content rather than personal photos with a shared demo account.
- The app stores library metadata and cached media on your iPhone. Offline availability depends on what has synced and remains cached; it does not keep every original photo or video offline.
- Sign-in tokens, Locked Folder PINs and optional connection credentials or certificates are stored in the iOS Keychain. Sign out to remove saved account credentials. Removing the app deletes its app data, but Keychain items may remain. Neither action deletes content or your account on the server.

Use the app's or server's controls to delete content. Contact your server administrator about account deletion, retention and server backups.

## Permissions

- **Photos:** to show the photos on your iPhone, back them up to your server, save downloads, and favorite or remove selected local photos when you ask. Removal uses iOS's confirmation prompt.
- **Location:** requested when you tap My location while choosing a photo location, or ask the app to read your Wi-Fi network's name for local server connections. Your current location is sent to your photo server only if you save it to a photo. Wi-Fi connection rules are stored locally.
- **Local network:** to reach a server on your home network.
- **Face ID:** to unlock your Locked Folder. Face ID data stays with iOS.

## Other services

Maps, address search and place labels use Apple Maps. These services may receive map regions, photo coordinates and search text under [Apple's privacy policy](https://www.apple.com/legal/privacy/). Single sign-on uses the identity provider configured by your server.

Purchases and subscriptions are processed by Apple's App Store. Ilyich checks verified purchase status on your device to determine app access. The developer does not receive your payment-card details or send purchase records to a developer billing server. Changing or deleting a photo-server account does not cancel an Apple subscription; manage subscriptions in your App Store account settings.

## AI and photo search

Photo content search and people recognition use your server's configured machine-learning services. If you turn on AI check, the server sends search text and photo previews to its configured verification service. Previews can include numbered face markers to check the people selected in a search.

Your server administrator chooses that service, which may run locally or on other infrastructure. Check the server's policy before using these features. The review demo runs verification on a locally hosted model; the developer provides no central AI service for other users' servers.

## Contact

For questions about Ilyich or this policy, [open a GitHub issue](https://github.com/ilyador/Ilyich/issues). Keep passwords, access tokens and personal photos out of public issues.
