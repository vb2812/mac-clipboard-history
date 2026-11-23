import CoreGraphics
import Foundation
// mouse click|right|move X Y | mouse drag X1 Y1 X2 Y2   (global top-left points). Refuses points inside system prompts.
let a = CommandLine.arguments
let src = CGEventSource(stateID: .hidSystemState)
func post(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left) {
    CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b)!.post(tap: .cghidEventTap)
}
let protectedOwners: Set<String> = ["UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent", "universalAccessAuthWarn"]
func insidePrompt(_ q: CGPoint) -> Bool {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.contains { w in
        guard let owner = w[kCGWindowOwnerName as String] as? String, protectedOwners.contains(owner),
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).insetBy(dx: -8, dy: -8).contains(q)
    }
}
let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
var targets = [p]
if a[1] == "drag" { targets.append(CGPoint(x: Double(a[4])!, y: Double(a[5])!)) }
if a[1] != "move", targets.contains(where: insidePrompt) { print("REFUSED: point is inside a system prompt"); exit(5) }
switch a[1] {
case "move": post(.mouseMoved, p)
case "click": post(.mouseMoved, p); usleep(60_000); post(.leftMouseDown, p); usleep(40_000); post(.leftMouseUp, p)
case "right": post(.mouseMoved, p); usleep(60_000); post(.rightMouseDown, p, .right); usleep(40_000); post(.rightMouseUp, p, .right)
case "drag":
    // Human-like: press, pause, small nudge to start the drag, slow travel, hover over the target, release.
    let q = targets[1]
    post(.mouseMoved, p); usleep(100_000); post(.leftMouseDown, p); usleep(300_000)
    for k in 1...6 { post(.leftMouseDragged, CGPoint(x: p.x + Double(k), y: p.y)); usleep(30_000) }
    for i in 1...60 { let t = Double(i) / 60; post(.leftMouseDragged, CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)); usleep(25_000) }
    for k in 0..<30 { post(.leftMouseDragged, CGPoint(x: q.x + Double(k % 2), y: q.y)); usleep(40_000) }
    post(.leftMouseUp, q)
default: break
}
