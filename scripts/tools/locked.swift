import CoreGraphics
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
let locked = (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
print(locked ? "locked" : "unlocked"); exit(locked ? 1 : 0)
