/// A photo can open in the viewer or be located in the main timeline. The
/// library resolves this only after the presenting sheet or story has closed.
enum PhotoDestination {
    case viewer(Asset)
    case timeline(Asset)
}
