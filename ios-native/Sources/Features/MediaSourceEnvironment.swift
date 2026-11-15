import SwiftUI

extension EnvironmentValues {
    /// The signed-in account's authoritative phone/server media source resolver.
    @Entry var mediaSources: MediaSourceResolver? = nil
}
