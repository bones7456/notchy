import Carbon

/// Thin wrapper around the Text Input Sources (TIS) API used to give each tab
/// its own keyboard input source. macOS only tracks a single system-wide input
/// source at a time, so "per-tab input methods" is simulated by capturing the
/// live source when leaving a tab and re-selecting the stored one when entering.
enum InputSourceManager {
    /// The currently selected keyboard input source ID (e.g.
    /// "com.apple.keylayout.ABC" or "com.apple.inputmethod.SCIM.ITABC").
    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return sourceID(of: source)
    }

    /// Select the input source with the given ID. No-op if it can't be found
    /// (e.g. the user removed that input source since it was recorded).
    static func select(id: String) {
        guard let source = source(withID: id) else { return }
        TISSelectInputSource(source)
    }

    /// Switch to an ASCII-capable (English) keyboard layout. Uses the most
    /// recently used ASCII source, which is what the user expects as "English".
    static func selectASCIICapable() {
        guard let source = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() else { return }
        TISSelectInputSource(source)
    }

    private static func sourceID(of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func source(withID id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first
    }
}
