# Ilyich support

For help, [open a GitHub issue](https://github.com/ilyador/Ilyich/issues).

Include your iPhone model, iOS version, Ilyich version, server version and the steps that caused the problem. Keep passwords, access tokens and personal photos out of public issues.

## Getting started

Ilyich connects to a compatible photo server using its address and your existing account. The app does not include photo hosting. Your server administrator manages accounts and server-side storage.

- **Purchases:** Full app access requires a subscription or lifetime purchase. Eligible new subscribers receive a one-week trial. Use Restore Purchases with the Apple account that purchased access; manage or cancel subscriptions in your App Store account settings. A lifetime purchase does not cancel an existing subscription. Server sign-out or account deletion does not cancel Apple billing.
- **Automatic backup:** Open Settings → Backup and choose Entire library or Selected albums, then enable Automatic backup. Allow Full Access in Photos for the entire library. Identical files already on your server are skipped automatically; completed backups are remembered. Enable Download iCloud originals for files stored only in iCloud. iOS decides when background work runs; the backup screen explains restrictions and provides a Settings link when applicable. You can still use Back up now while the app is open.
- **Offline browsing:** Saved library information and cached images remain available. Media that has not been cached needs a server connection.
- **Search:** Photo-content search depends on the server's machine-learning setup. AI check requires a compatible, configured server and is off by default.
- **Free up space:** The app offers local photos only after verifying their server backups. Review the selection and the Photos confirmation prompt before removal.

[Privacy policy](PRIVACY.md)

- **Backup numbers:** Selected is your backup scope. Verified includes existing backups checked by this phone; it is not a new-upload counter. Not checked yet may also already exist on the server. To upload counts items checked as missing. For older backups without a reusable identity, Ilyich may need to read or download an original to compare it; identical files are skipped. The bottom status opens these details.
- **Background refresh warning:** Check iOS Settings → General → Background App Refresh and the Ilyich app setting. An app switch can look enabled while the global setting is off. Foreground backup still works.
- **Opening phone photos:** Verified server copies use the server viewer. A server outage offers retry and an explicit phone fallback. Unmatched photos can use Apple Photos; iCloud-only resources show download, progress and cancel controls.
