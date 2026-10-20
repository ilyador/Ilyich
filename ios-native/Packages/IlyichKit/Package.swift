// swift-tools-version: 6.0
import PackageDescription

// Code the app shares with its Share and Widget extensions: account identity and storage
// names, the App Group, the saved session and the server connection. Everything here must be
// usable from an app extension.
let package = Package(
    name: "IlyichKit",
    platforms: [.iOS("27.0")],
    products: [.library(name: "IlyichPlatform", targets: ["IlyichPlatform"])],
    targets: [.target(name: "IlyichPlatform")]
)
