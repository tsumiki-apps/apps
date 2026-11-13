// 入力を捨てる口（CGEventTap・HID の段）。アクセシビリティの許可が要る。
// 口はこのアプリの中にしか無いので、アプリが終われば（落ちても）入力は必ず戻る。
import Foundation
import CoreGraphics

final class Blocker {
    private(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    private var _hold = Hold()
    private(set) var dropped: [UInt32: Int] = [:]

    var hold: Hold { lock.lock(); defer { lock.unlock() }; return _hold }
    var isOn: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        stop()
        lock.lock(); _hold = Hold(); dropped = [:]; lock.unlock()
        let cb: CGEventTapCallBack = { _, type, event, ref in
            Unmanaged<Blocker>.fromOpaque(ref!).takeUnretainedValue().handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: Core.mask, callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    /// 1件ごと。止めた入力は捨てる（nil）。macOS に口を止められたら（重すぎ・ほかの入力）すぐ開け直す
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let raw = type.rawValue
        lock.lock()
        if Core.downTypes.contains(raw) || Core.upTypes.contains(raw) {
            let btn = event.getIntegerValueField(.mouseEventButtonNumber)
            if Core.downTypes.contains(raw) { _hold.down(ProcessInfo.processInfo.systemUptime, btn) } else { _hold.up(btn) }
        }
        dropped[raw, default: 0] += 1
        lock.unlock()
        return nil
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
}
