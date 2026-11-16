# Native builds

For the owner's phones, run `scripts/owner-device.sh <version> <build> <device-id>` on the signing Mac, or select **IlyichOwner** in Xcode. The dedicated **Owner** configuration enables owner access. The helper checks the compiled app before installing over the existing app; it preserves app data and does not launch the app.

Use **IlyichCommerce** for StoreKit tests and `scripts/app-store.sh` for App Store archives. These use normal purchase verification. Release builds reject the owner flag.

Build 3040122 was accidentally compiled as ordinary Debug, causing the owner's phone to show the payment screen. Build 3040123 restores owner access. Future owner installs must use the named configuration and helper rather than ad hoc compilation flags.
