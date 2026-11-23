import ApplicationServices
import AppKit
// Times the focused-element query and reports role/frame (what Clipboard History's caret fallback sees). Arg "app" queries the frontmost app element.
let useApp = CommandLine.arguments.contains("app")
let pid = NSWorkspace.shared.frontmostApplication!.processIdentifier
let root = useApp ? AXUIElementCreateApplication(pid) : AXUIElementCreateSystemWide()
if useApp { print("set AXManualAccessibility rc=\(AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)") }
let t0 = Date()
var f: CFTypeRef?
let rc = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &f)
print("front=\(NSWorkspace.shared.frontmostApplication!.bundleIdentifier ?? "?") focused rc=\(rc.rawValue) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
if let e = f { let el = e as! AXUIElement
    var r: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
    var p: CFTypeRef?, s: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p); AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s)
    var o = CGPoint.zero, z = CGSize.zero; if let p { AXValueGetValue(p as! AXValue, .cgPoint, &o) }; if let s { AXValueGetValue(s as! AXValue, .cgSize, &z) }
    var sr: CFTypeRef?; let src = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sr)
    print("role=\(r as? String ?? "?") frame=\(o) \(z) selectedRange rc=\(src.rawValue)") }
