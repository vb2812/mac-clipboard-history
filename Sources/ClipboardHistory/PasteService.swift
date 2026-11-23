import AppKit
import Carbon.HIToolbox

/// Writes items back to the pasteboard and synthesizes ⌘V.
@MainActor
enum PasteService {
    /// Writes the item; returns the new changeCount so the monitor can ignore it.
    @discardableResult
    static func write(_ reps: [Representation], plainText: String?, asPlain: Bool,
                      to pb: NSPasteboard = .general) -> Int {
        pb.clearContents()
        if asPlain, let text = plainText {
            pb.setString(text, forType: .string)
        } else if let files = reps.first(where: { $0.type == ClipBuilder.fileURL }) {
            pb.writeObjects(ClipBuilder.fileURLs(from: files.data) as [NSURL])
        } else {
            pb.declareTypes(reps.map { .init($0.type) }, owner: nil)
            for rep in reps { pb.setData(rep.data, forType: .init(rep.type)) }
        }
        if let id = Bundle.main.bundleIdentifier { pb.setString(id, forType: .source) }
        return pb.changeCount
    }

    static var canAutoPaste: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPBOARD_HISTORY_FORCE_COPY_ONLY"] != nil { return false }   // tests the no-Accessibility path
        #endif
        return AXIsProcessTrusted() && !IsSecureEventInputEnabled()
    }

    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt (a global var, not concurrency-safe)
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Posts ⌘V to the frontmost app. Uses the key that types "v" in the current layout.
    static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Finds the virtual key code that types `char` while ⌘ is held, in the current keyboard layout
    /// (Dvorak, AZERTY…). Translating with ⌘ down matters for "Dvorak – QWERTY ⌘", where shortcuts use QWERTY keys.
    static func keyCode(for char: Character, in source: TISInputSource? = nil) -> CGKeyCode? {
        guard let source = source ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let rc = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), commandState, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if rc == noErr, len == 1, let scalar = UnicodeScalar(chars[0]),
                   Character(scalar).lowercased() == String(char) { return CGKeyCode(code) }
            }
            return nil
        }
    }

    /// An installed keyboard layout by ID (doesn't need to be enabled); used by tests.
    static func layout(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }
}
