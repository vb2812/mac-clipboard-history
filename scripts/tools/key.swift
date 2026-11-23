import CoreGraphics
import Foundation
// key <keycode> [cmd] [opt] [shift] [ctrl] [fn] [numpad] [--repeat N] [--interval S]
let a = CommandLine.arguments
let code = CGKeyCode(Int(a[1])!)
var flags: CGEventFlags = []
if a.contains("cmd") { flags.insert(.maskCommand) }
if a.contains("opt") { flags.insert(.maskAlternate) }
if a.contains("shift") { flags.insert(.maskShift) }
if a.contains("ctrl") { flags.insert(.maskControl) }
if a.contains("fn") { flags.insert(.maskSecondaryFn) }
if a.contains("numpad") { flags.insert(.maskNumericPad) }
let rep = a.firstIndex(of: "--repeat").map { Int(a[$0 + 1])! } ?? 1
let gap = a.firstIndex(of: "--interval").map { useconds_t(Double(a[$0 + 1])! * 1_000_000) } ?? 0
let src = CGEventSource(stateID: .hidSystemState)
let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!; d.flags = flags
let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!; u.flags = flags
for _ in 0..<rep { d.post(tap: .cghidEventTap); usleep(5_000); u.post(tap: .cghidEventTap); if rep > 1 { usleep(gap) } }
