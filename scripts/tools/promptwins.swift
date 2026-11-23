import CoreGraphics
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info { if let o = w[kCGWindowOwnerName as String] as? String, ["UserNotificationCenter","CoreServicesUIAgent","SecurityAgent"].contains(o), let b = w[kCGWindowBounds as String] as? [String: CGFloat] { print(o, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!)) } }
