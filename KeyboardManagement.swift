import Foundation
import IOKit
import CryptoKit
import Darwin

enum KeyboardMode: String, Codable, CaseIterable {
    case on, `default`, off
    func applies(defaultEnabled: Bool) -> Bool {
        self == .on || (self == .default && defaultEnabled)
    }
}

struct KeyboardIdentity {
    let key: String
    let detail: String
    // Registry IDs identify a connection, never a saved user preference.
    init(properties: [String: String]) {
        let name = properties["Product"] ?? "키보드"
        let transport = properties["Transport"] ?? ""
        var parts = [properties["VendorID"] ?? "0", properties["ProductID"] ?? "0", transport]
        let serial = properties["SerialNumber"] ?? ""
        let unique = properties["PhysicalDeviceUniqueID"] ?? ""
        let location = properties["LocationID"] ?? "0"
        if !serial.isEmpty && serial != "0" {
            parts += ["serial", serial]
            detail = transport.isEmpty ? "키보드" : transport
        } else if !unique.isEmpty && unique != "0" {
            parts += ["physical", unique]
            detail = transport.isEmpty ? "키보드" : transport
        } else if properties["Built-In"] == "1" {
            parts += ["built-in", name]
            detail = "내장 키보드"
        } else if location != "0" && !location.isEmpty {
            parts += ["location", location, name]
            detail = "\(transport.isEmpty ? "키보드" : transport) · 포트 \(location)"
        } else {
            // Some virtual/anonymous devices expose no persistent identifier.
            // Be explicit that indistinguishable services share one preference.
            let normalizedName = name.hasPrefix("Karabiner DriverKit VirtualHIDKeyboard")
                ? "Karabiner DriverKit VirtualHIDKeyboard" : name
            parts += ["model", normalizedName]
            detail = "같은 모델에 함께 적용"
        }
        let data = try! JSONEncoder().encode(parts)
        key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct SavedKeyboard: Codable, Equatable {
    let key: String
    var name: String
    var detail: String
    var mode: KeyboardMode
}

protocol KeyboardDevice: AnyObject {
    var registryID: String { get }
    var name: String { get }
    var identity: KeyboardIdentity { get }
    func readMappings() throws -> [Mapping]
    func writeMappings(_ mappings: [Mapping]) throws
}

enum KeyboardError: Error, LocalizedError {
    case enumeration, read, write, verification, conflict
    var errorDescription: String? {
        switch self {
        case .enumeration: return "키보드 목록을 확인하지 못했습니다."
        case .read: return "키보드 매핑을 읽지 못했습니다."
        case .write: return "키보드 매핑을 적용하지 못했습니다."
        case .verification: return "키보드 매핑 적용을 확인하지 못했습니다."
        case .conflict: return "전환 키가 다른 매핑에서 사용 중입니다."
        }
    }
}

final class HIDKeyboardDevice: KeyboardDevice {
    // A service must not outlive the client that created it.
    private let client: IOHIDEventSystemClient
    private let service: IOHIDServiceClient
    let registryID: String
    let name: String
    let identity: KeyboardIdentity
    init(client: IOHIDEventSystemClient, service: IOHIDServiceClient) {
        self.client = client; self.service = service
        registryID = String(describing: IOHIDServiceClientGetRegistryID(service))
        var properties: [String: String] = [:]
        for key in ["Product", "VendorID", "ProductID", "Transport", "SerialNumber", "PhysicalDeviceUniqueID", "LocationID", "Built-In"] {
            if let value = IOHIDServiceClientCopyProperty(service, key as CFString) {
                properties[key] = (value as? String) ?? (value as? NSNumber)?.stringValue
            }
        }
        name = properties["Product"] ?? "이름 없는 키보드"
        identity = KeyboardIdentity(properties: properties)
    }
    func readMappings() throws -> [Mapping] {
        guard let value = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) else { return [] }
        guard let mappings = value as? [Mapping] else { throw KeyboardError.read }
        return mappings
    }
    func writeMappings(_ mappings: [Mapping]) throws {
        guard IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, mappings as CFArray) else { throw KeyboardError.write }
    }
    static func discover() throws -> [KeyboardDevice] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { throw KeyboardError.enumeration }
        return services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }
            .map { HIDKeyboardDevice(client: client, service: $0) }
    }
}

struct KeyboardFailure {
    var count: Int
    var name: String
    var reason: String
}

struct KeyboardReconcileResult {
    var applied = 0
    var selected = 0
    var pending = 0
}

final class KeyboardManager {
    let defaults: UserDefaults
    let discover: () throws -> [KeyboardDevice]
    private(set) var known: [String: SavedKeyboard]
    private(set) var connected: Set<String> = []
    private(set) var failures: [String: KeyboardFailure] = [:]
    private(set) var result = KeyboardReconcileResult()
    var defaultEnabled: Bool {
        get { defaults.object(forKey: "keyboardDefaultEnabled") == nil || defaults.bool(forKey: "keyboardDefaultEnabled") }
        set { defaults.set(newValue, forKey: "keyboardDefaultEnabled") }
    }
    var records: [String: [String: String]] {
        get { defaults.dictionary(forKey: "records") as? [String: [String: String]] ?? [:] }
        set { if newValue != records { defaults.set(newValue, forKey: "records") } }
    }
    var keyboards: [SavedKeyboard] {
        known.values.sorted {
            if connected.contains($0.key) != connected.contains($1.key) { return connected.contains($0.key) }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.key < $1.key
        }
    }
    var warning: String? {
        let persistent = failures.values.filter { $0.count >= 3 }
        guard !persistent.isEmpty else { return nil }
        if let listFailure = failures["enumeration"], listFailure.count >= 3 {
            return "키보드 목록을 확인하지 못해 다시 시도하고 있습니다."
        }
        return "일부 키보드에 설정을 적용하지 못해 다시 시도하고 있습니다."
    }
    var warningDetails: String? {
        let details = failures.values.filter { $0.count >= 3 }
            .sorted { $0.name < $1.name }.map { "\($0.name): \($0.reason)" }
        return details.isEmpty ? nil : details.joined(separator: "\n")
    }
    static var bootSession: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
    init(defaults: UserDefaults, discover: @escaping () throws -> [KeyboardDevice] = HIDKeyboardDevice.discover, bootSession: String? = KeyboardManager.bootSession) {
        self.defaults = defaults; self.discover = discover
        known = defaults.data(forKey: "knownKeyboards").flatMap { try? JSONDecoder().decode([String: SavedKeyboard].self, from: $0) } ?? [:]
        if let bootSession {
            if let previousBoot = defaults.string(forKey: "keyboardRecordsBoot"), previousBoot != bootSession {
                // HID mappings do not survive reboot. An old registry ID can belong to a different device now.
                defaults.removeObject(forKey: "records")
            }
            defaults.set(bootSession, forKey: "keyboardRecordsBoot")
        }
    }
    private func saveKnown() { defaults.set(try! JSONEncoder().encode(known), forKey: "knownKeyboards") }
    func setMode(_ mode: KeyboardMode, for key: String) {
        guard known[key] != nil else { return }
        known[key]?.mode = mode; saveKnown()
    }
    func isSelected(_ device: KeyboardDevice) -> Bool {
        (known[device.identity.key]?.mode ?? .default).applies(defaultEnabled: defaultEnabled)
    }
    func snapshot() throws -> [KeyboardDevice] {
        let devices = try discover()
        connected = Set(devices.map { $0.identity.key })
        var updated = known
        for device in devices {
            let key = device.identity.key
            updated[key] = SavedKeyboard(key: key, name: device.name, detail: device.identity.detail, mode: known[key]?.mode ?? .default)
        }
        if updated != known { known = updated; saveKnown() }
        return devices
    }
    private func failed(_ key: String, name: String, error: Error) {
        failures[key] = KeyboardFailure(count: min((failures[key]?.count ?? 0) + 1, 3), name: name, reason: error.localizedDescription)
    }
    private func setVerified(_ desired: [Mapping], current: [Mapping], device: KeyboardDevice) throws {
        guard !mappingEqual(current, desired) else { return }
        try device.writeMappings(desired)
        guard mappingEqual(try device.readMappings(), desired) else { throw KeyboardError.verification }
    }
    // Compare semantic entries, not an incidental array order from a driver.
    static func canonical(_ mappings: [Mapping]) -> [String] {
        mappings.map { row in row.keys.sorted().map { "\($0)=\(row[$0]!)" }.joined(separator: ",") }.sorted()
    }
    private func mappingEqual(_ lhs: [Mapping], _ rhs: [Mapping]) -> Bool { Self.canonical(lhs) == Self.canonical(rhs) }
    private func restore(_ device: KeyboardDevice) throws {
        var saved = records
        guard let old = saved[device.registryID], let source = UInt64(old["source"] ?? ""), let target = UInt64(old["target"] ?? "") else { return }
        let current = try device.readMappings()
        let pendingTarget = UInt64(old["pendingTarget"] ?? "")
        if current.contains(where: { $0[srcKey]?.uint64Value == source && ($0[dstKey]?.uint64Value == target || (pendingTarget != nil && $0[dstKey]?.uint64Value == pendingTarget)) }) {
            var desired = current.filter { $0[srcKey]?.uint64Value != source }
            if let original = UInt64(old["original"] ?? "") { desired.append([srcKey: NSNumber(value: source), dstKey: NSNumber(value: original)]) }
            try setVerified(desired, current: current, device: device)
        }
        saved.removeValue(forKey: device.registryID); records = saved
    }
    private func apply(_ device: KeyboardDevice, source: UInt64, target: UInt64) throws {
        // Complete an old source's undo before starting a new ownership record.
        if let old = records[device.registryID], old["source"] != String(source) { try restore(device) }
        let current = try device.readMappings()
        var saved = records
        guard !targetConflict(current, source: source, target: target, owned: saved[device.registryID]) else { throw KeyboardError.conflict }
        let desired = merged(current, source: source, previous: source, original: nil, target: target)
        if let old = saved[device.registryID], old["target"] == String(target), old["pendingTarget"] == nil,
           mappingEqual(current, desired) { return }
        var record = saved[device.registryID] ?? [
            "source": String(source),
            "original": current.first { $0[srcKey]?.uint64Value == source }?[dstKey].map { String($0.uint64Value) } ?? "none",
            "target": String(target)
        ]
        // Save undo before touching hardware; remember both outcomes of a failed readback.
        record["pendingTarget"] = String(target)
        saved[device.registryID] = record; records = saved
        try setVerified(desired, current: current, device: device)
        record["target"] = String(target); record.removeValue(forKey: "pendingTarget")
        saved[device.registryID] = record; records = saved
    }
    @discardableResult func reconcile(source: UInt64, target: UInt64, active: Bool) -> KeyboardReconcileResult {
        var next = KeyboardReconcileResult()
        let devices: [KeyboardDevice]
        do { devices = try snapshot(); failures.removeValue(forKey: "enumeration") }
        catch { failed("enumeration", name: "키보드 목록", error: error); next.pending = 1; result = next; return next }
        let present = Set(devices.map(\.registryID))
        failures = failures.filter { present.contains($0.key) }
        var failedIDs: Set<String> = []
        for device in devices {
            let selected = active && isSelected(device)
            if selected { next.selected += 1 }
            do {
                if selected { try apply(device, source: source, target: target); next.applied += 1 }
                else { try restore(device) }
                failures.removeValue(forKey: device.registryID)
            } catch {
                failedIDs.insert(device.registryID)
                failed(device.registryID, name: device.name, error: error)
            }
        }
        if !failedIDs.isEmpty {
            // A removal between enumeration and write is expected; do not warn about it.
            if let latest = try? snapshot() {
                let live = Set(latest.map(\.registryID))
                failures = failures.filter { live.contains($0.key) }
                failedIDs.formIntersection(live)
            }
        }
        next.pending = failedIDs.count
        result = next
        return next
    }
}
