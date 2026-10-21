// swift-tools-version: 6.0
import PackageDescription

// Code the app shares with its Share and Widget extensions. IlyichPlatform: account identity
// and storage names, the App Group, the saved session and the server connection.
// IlyichShareInbox: the share inbox the Share extension stages into and the app uploads from.
// Everything here must be usable from an app extension.
let package = Package(
    name: "IlyichKit",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "IlyichPlatform", targets: ["IlyichPlatform"]),
        .library(name: "IlyichShareInbox", targets: ["IlyichShareInbox"]),
    ],
    targets: [
        .target(name: "IlyichPlatform"),
        .target(name: "IlyichShareInbox", dependencies: ["IlyichPlatform"]),
    ]
)
