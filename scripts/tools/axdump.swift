import ApplicationServices
import Foundation
// axdump <pid> [maxLines] — role | label [selected] @x,y wxh for labelled elements of the app's windows
let pid = pid_t(Int32(CommandLine.arguments[1])!)
let maxLines = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 60
var lines = 0
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func walk(_ e: AXUIElement, _ depth: Int) {
    guard lines < maxLines, depth < 30 else { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let label = (attr(e, kAXDescriptionAttribute) as? String) ?? (attr(e, kAXTitleAttribute) as? String) ?? (attr(e, kAXValueAttribute) as? String) ?? ""
    let sel = (attr(e, kAXSelectedAttribute) as? Bool) == true ? " [selected]" : ""
    var pos = CGPoint.zero, size = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &pos) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    if !label.isEmpty || role == "AXButton" || role == "AXTextField" {
        print(String(repeating: " ", count: depth) + role + " | " + String(label.prefix(70)) + sel + " @\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height))")
        lines += 1
    }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, depth + 1) }
}
let app = AXUIElementCreateApplication(pid)
for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
