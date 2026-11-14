// Read-only observer for compare_installed_audio.py. No GUI actions or audio capture.
import AppKit
import ApplicationServices
import CoreAudio
import Foundation

guard CommandLine.arguments.count == 2 else { exit(2) }
let targetTitle = CommandLine.arguments[1]
func emit(_ kind: String, _ fields: [String: Any] = [:]) {
    var d = fields; d["kind"] = kind; d["tickNs"] = DispatchTime.now().uptimeNanoseconds
    if let b = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(b + Data([10]))
    }
}
func attr(_ x: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(x, key as CFString, &v) == .success else { return nil }
    return v
}
let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
let callback: CGEventTapCallBack = { _, type, event, _ in
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    // No general keyboard logging: only the enrolled/portable F5 and cancellation.
    if [53, 79, 96].contains(key) {
        emit("key", ["keyCode": key, "eventType": type.rawValue,
                     "repeat": event.getIntegerValueField(.keyboardEventAutorepeat)])
    }
    return Unmanaged.passUnretained(event)
}
let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil)
emit("preflight", ["AXTrusted": AXIsProcessTrusted(), "HIDTapAvailable": tap != nil])
guard AXIsProcessTrusted(), let tap else { exit(3) }
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
var lastFront = "", lastField = "", previousFieldPoll: UInt64 = 0
var lastMic: UInt32?, lastInput: AudioObjectID = 0
let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
    let began = DispatchTime.now().uptimeNanoseconds
    var device: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr {
        if device != lastInput { emit("input-device", ["deviceID": device]); lastInput = device; lastMic = nil }
        var running: UInt32 = 0; size = 4; address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr, running != lastMic {
            emit("microphone", ["deviceID": device, "running": running != 0]); lastMic = running
        }
    }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    if front != lastFront { emit("frontmost", ["bundleID": front]); lastFront = front }
    var row: [String: Any] = ["valid": false]
    if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.processIdentifier {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        if let raw = attr(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID(),
           attr(raw as! AXUIElement, kAXTitleAttribute) as? String == targetTitle,
           let field = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(field) == AXUIElementGetTypeID() {
            let field = field as! AXUIElement
            let role = attr(field, kAXRoleAttribute) as? String ?? ""
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
            if [kAXTextAreaRole as String, kAXTextFieldRole as String].contains(role), settable.boolValue,
               let text = attr(field, kAXValueAttribute) as? String {
                row = ["valid": true, "window": targetTitle, "text": text, "frontmost": front == "com.apple.TextEdit"]
            }
        }
    }
    // Do not read or emit text/title from any other document.
    let key = (try? String(data: JSONSerialization.data(withJSONObject: row.filter { $0.key != "frontmost" }, options: [.sortedKeys]), encoding: .utf8)) ?? ""
    if key != lastField {
        row["pollStartedNs"] = began; row["previousFieldPollTickNs"] = previousFieldPoll
        emit("field", row); lastField = key
    }
    previousFieldPoll = began
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
