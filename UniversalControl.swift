import AppKit
import IOKit.hid

// Universal Control. With the pointer on another Mac, this Mac's keys go there already mapped, before any event tap here
// sees them, and Universal Control is in front here meanwhile. The other Mac types them with the sending keyboard
// service's own Caps Lock: a lock set there, or this Mac's global one, gives way to it on the next key.
let universalControlID = "com.apple.universalcontrol"

// A long press the tap here never saw went to the other Mac. One it saw this close to the device's is this Mac's.
func remoteLongPress(down: TimeInterval, tapDown: TimeInterval?) -> Bool {
    guard let tapDown else { return true }
    return abs(tapDown - down) > 0.3
}

// The sending Mac's side: a long press of the Korean/English key there turns uppercase on with this keyboard's lock.
// Watched on the keyboard devices only while Universal Control is in front, with Input Monitoring.
final class RemoteHoldMonitor {
    let target: () -> UInt64
    let tapDown: () -> TimeInterval?
    private var manager: IOHIDManager?
    // Once each time Universal Control comes to the front, so a refusal is not asked about again meanwhile.
    private var tried = false
    private var held: (usage: UInt32, task: DispatchWorkItem)?
    init(target: @escaping () -> UInt64, tapDown: @escaping () -> TimeInterval?) { self.target = target; self.tapDown = tapDown }
    deinit { stop() }
    // `enabled` is whether a long press of a mapped key here would switch the case at all.
    func update(enabled: Bool) {
        guard enabled, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == universalControlID else { stop(); tried = false; return }
        guard manager == nil, !tried else { return }
        tried = true
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            // Only the first request shows the system prompt. Off the main thread, where the tap runs.
            DispatchQueue.global().async { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<RemoteHoldMonitor>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Karabiner-Elements seizes the keyboards it reads, so this reports exclusive access, yet its virtual keyboard reports.
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }
    private func stop() {
        held?.task.cancel(); held = nil
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }
    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let usage = IOHIDElementGetUsage(element)
        guard IOHIDValueGetIntegerValue(value) != 0 else {
            if held?.usage == usage { held?.task.cancel(); held = nil }
            return
        }
        let key = 0x700000000 | UInt64(usage)
        guard sources.contains(key), held?.usage != usage else { return }
        held?.task.cancel()
        let device = IOHIDElementGetDevice(element), down = ProcessInfo.processInfo.systemUptime
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.held?.usage == usage else { return }
            self.held = nil
            if remoteLongPress(down: down, tapDown: self.tapDown()) { Self.toggleCapsLock(of: device, key: key, target: self.target()) }
        }
        held = (usage, task)
        DispatchQueue.main.asyncAfter(deadline: .now() + LongPressState.delay, execute: task)
    }
    // The device's keyboard services that send the key as the Korean/English key's F-key carry the lock to the other Mac.
    private static func toggleCapsLock(of device: IOHIDDevice, key: UInt64, target: UInt64) {
        let ids = registryIDs(under: IOHIDDeviceGetService(device))
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        // The services stay valid only as long as the client.
        withExtendedLifetime(client) {
            guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return }
            let keyboards = services.filter { service in
                guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0,
                      let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value, ids.contains(id) else { return false }
                let mappings = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [Mapping] ?? []
                return mappings.contains { $0[srcKey]?.uint64Value == key && $0[dstKey]?.uint64Value == target }
            }
            let on = keyboards.contains { (IOHIDServiceClientCopyProperty($0, "HIDCapsLockState" as CFString) as? NSNumber)?.boolValue == true }
            for service in keyboards { _ = IOHIDServiceClientSetProperty(service, "HIDCapsLockState" as CFString, (!on) as CFBoolean) }
        }
    }
    private static func registryIDs(under service: io_service_t) -> Set<UInt64> {
        var ids: Set<UInt64> = [], id: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.insert(id) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return ids }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            if IORegistryEntryGetRegistryEntryID(child, &id) == KERN_SUCCESS { ids.insert(id) }
            IOObjectRelease(child)
        }
        return ids
    }
}

// The receiving Mac's side. Universal Control's keys come from services hidd keeps for the other Mac's keyboards, which
// the kernel registry does not have. This Mac's keyboards, Karabiner's virtual one, and posted events' IOHIDSystem are there.
struct RemoteKeyboards {
    // The HID service an event came from, an undocumented field.
    static let senderField = CGEventField(rawValue: 87)
    var inKernel: (UInt64) -> Bool = { id in
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }
    // Registry IDs are not reused, so each is looked up once.
    private var remote: [UInt64: Bool] = [:]
    mutating func sentFromOtherMac(_ event: CGEvent) -> Bool {
        guard let field = Self.senderField else { return false }
        let id = UInt64(bitPattern: event.getIntegerValueField(field))
        guard id != 0 else { return false }
        if let known = remote[id] { return known }
        let found = !inKernel(id)
        remote[id] = found
        return found
    }
}
