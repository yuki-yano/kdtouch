import Foundation
import CoreGraphics
import IOKit

struct BrightnessReading: Equatable {
    let current: UInt16
    let maximum: UInt16

    init?(current: UInt16, maximum: UInt16) {
        guard maximum > 0, current <= maximum else { return nil }
        self.current = current
        self.maximum = maximum
    }

    var percent: Int { (Int(current) * 100 + Int(maximum) / 2) / Int(maximum) }

    func value(for percent: Int) throws -> UInt16 {
        guard (0...100).contains(percent) else { throw BrightnessError.invalidPercent }
        return UInt16((percent * Int(maximum) + 50) / 100)
    }
}

enum BrightnessState {
    case disconnected
    case busy(last: BrightnessReading?)
    case ready(BrightnessReading)
    case adjusting(requested: Int, last: BrightnessReading)
    case failed(message: String, last: BrightnessReading?)

    var reading: BrightnessReading? {
        switch self {
        case .disconnected: return nil
        case let .busy(last), let .failed(_, last): return last
        case let .ready(reading), let .adjusting(_, reading): return reading
        }
    }

    var displayedPercent: Int? {
        if case let .adjusting(requested, _) = self { return requested }
        return reading?.percent
    }
}

enum BrightnessError: LocalizedError {
    case unavailable, invalidReply, invalidPercent, invalidSavedValue, readbackMismatch
    case communication(IOReturn)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "輝度の接続先を特定できません"
        case .invalidReply: return "輝度の応答が不正です"
        case .invalidPercent: return "輝度は0〜100%で指定してください"
        case .invalidSavedValue: return "保存された輝度が不正です"
        case .readbackMismatch: return "輝度の変更を確認できません"
        case let .communication(code): return String(format: "輝度の通信に失敗: 0x%08x", code)
        }
    }
}

enum BrightnessPacket {
    static let read: [UInt8] = [0x82, 0x01, 0x10, 0xac]

    static func set(_ value: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xff)]
        bytes.append(bytes.reduce(0x6e ^ 0x51, ^))
        return bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> BrightnessReading {
        guard bytes.count == 11 || bytes.count == 12,
              bytes[0] == 0x6e, bytes[1] == 0x88, bytes[2] == 0x02,
              bytes[3] == 0, bytes[4] == 0x10, bytes[5] == 0,
              bytes.prefix(11).reduce(0x50, ^) == 0,
              let reading = BrightnessReading(current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
                                              maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7])) else {
            throw BrightnessError.invalidReply
        }
        return reading
    }
}

func savedBrightnessPercent(_ object: Any?) throws -> Int? {
    guard let object else { return nil }
    guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, (0...100).contains(number.doubleValue),
          number.doubleValue.rounded() == number.doubleValue else {
        throw BrightnessError.invalidSavedValue
    }
    return number.intValue
}

@_silgen_name("CoreDisplay_DisplayCreateInfoDictionary")
private func displayInfo(_ id: CGDirectDisplayID) -> Unmanaged<CFDictionary>?
@_silgen_name("IOAVServiceCreateWithService")
private func createAVService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func readI2C(_ service: CFTypeRef, _ chip: UInt32, _ address: UInt32,
                     _ bytes: UnsafeMutableRawPointer, _ count: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func writeI2C(_ service: CFTypeRef, _ chip: UInt32, _ address: UInt32,
                      _ bytes: UnsafeMutableRawPointer, _ count: UInt32) -> IOReturn

final class KD1DDC {
    private let service: CFTypeRef

    init(displayID: CGDirectDisplayID) throws {
        guard CGDisplayIsOnline(displayID) != 0,
              let info = displayInfo(displayID)?.takeRetainedValue() as NSDictionary?,
              let names = info["DisplayProductName"] as? [String: String], names.values.contains("KD1"),
              let location = info["IODisplayLocation"] as? String else { throw BrightnessError.unavailable }
        let framebuffer = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard framebuffer != 0 else { throw BrightnessError.unavailable }
        defer { IOObjectRelease(framebuffer) }
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(framebuffer, kIOServicePlane, &device) == KERN_SUCCESS else {
            throw BrightnessError.unavailable
        }
        defer { IOObjectRelease(device) }
        guard let deviceName = Self.name(of: device),
              let matching = IOServiceMatching("DCPAVServiceProxy") else { throw BrightnessError.unavailable }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw BrightnessError.unavailable
        }
        defer { IOObjectRelease(iterator) }
        var selected: io_service_t = 0
        var count = 0
        defer { if selected != 0 { IOObjectRelease(selected) } }
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            defer { IOObjectRelease(candidate) }
            guard let location = IORegistryEntryCreateCFProperty(candidate, "Location" as CFString,
                                                                 kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  location == "External" else { continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(candidate, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            // framebufferとproxyは別branchにあるため、共有するdevice名で経路を厳密に照合する。
            guard Self.name(of: parent) == "\(deviceName):dcpav-service-epic:0" else { continue }
            count += 1
            if selected == 0 { IOObjectRetain(candidate); selected = candidate }
        }
        guard count == 1, let service = createAVService(kCFAllocatorDefault, selected)?.takeRetainedValue() else {
            throw BrightnessError.unavailable
        }
        self.service = service
    }

    private static func name(of entry: io_registry_entry_t) -> String? {
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }

    private func send(_ packet: [UInt8]) throws {
        var bytes = packet
        for _ in 0..<2 {
            usleep(10_000)
            let result = writeI2C(service, 0x37, 0x51, &bytes, UInt32(bytes.count))
            guard result == kIOReturnSuccess else { throw BrightnessError.communication(result) }
        }
    }

    func read() throws -> BrightnessReading {
        try send(BrightnessPacket.read)
        usleep(50_000)
        var bytes = [UInt8](repeating: 0, count: 12)
        let result = readI2C(service, 0x37, 0x51, &bytes, UInt32(bytes.count))
        guard result == kIOReturnSuccess else { throw BrightnessError.communication(result) }
        return try BrightnessPacket.decode(bytes)
    }

    func setAndVerify(percent: Int, using reading: BrightnessReading) throws -> BrightnessReading {
        let value = try reading.value(for: percent)
        try send(BrightnessPacket.set(value))
        usleep(50_000)
        let confirmed = try read()
        guard confirmed.maximum == reading.maximum, confirmed.current == value else {
            throw BrightnessError.readbackMismatch
        }
        return confirmed
    }
}

final class BrightnessController {
    static let savedKey = "brightnessPercent"
    var onChange: ((BrightnessState) -> Void)?
    private(set) var state: BrightnessState = .disconnected {
        didSet { onChange?(state) }
    }
    private let defaults: UserDefaults
    private let communicate: (CGDirectDisplayID, Int?) throws -> BrightnessReading
    private let queue = DispatchQueue(label: "KDTouch.brightness", qos: .userInitiated)
    private var displayID: CGDirectDisplayID?
    private var generation: UInt64 = 0
    private var work: DispatchWorkItem?

    init(defaults: UserDefaults = .standard,
         communicate: @escaping (CGDirectDisplayID, Int?) throws -> BrightnessReading = { displayID, percent in
             let ddc = try KD1DDC(displayID: displayID)
             let reading = try ddc.read()
             if let percent { return try ddc.setAndVerify(percent: percent, using: reading) }
             return reading
         }) {
        self.defaults = defaults
        self.communicate = communicate
    }

    func connect(displayID: CGDirectDisplayID?) {
        guard self.displayID != displayID else { return }
        self.displayID = displayID
        generation &+= 1
        work?.cancel()
        state = .disconnected
        guard displayID != nil else { return }
        do {
            let percent = try savedBrightnessPercent(defaults.object(forKey: Self.savedKey))
            state = .busy(last: nil)
            perform(percent: percent, saving: false)
        } catch { state = .failed(message: error.localizedDescription, last: nil) }
    }

    func refresh() {
        switch state {
        case .busy, .adjusting, .disconnected: return
        case .ready, .failed: break
        }
        state = .busy(last: state.reading)
        perform(percent: nil, saving: false)
    }

    func set(percent: Int) {
        guard (0...100).contains(percent) else { return }
        switch state {
        case let .ready(reading):
            state = .adjusting(requested: percent, last: reading)
            perform(percent: percent, saving: true)
        case let .adjusting(_, last): state = .adjusting(requested: percent, last: last)
        case .disconnected, .busy, .failed: return
        }
    }

    private func perform(percent: Int?, saving: Bool) {
        guard let displayID else { return }
        let generation = generation
        let communicate = communicate
        let item = DispatchWorkItem { [weak self] in
            let result = Result { try communicate(displayID, percent) }
            // menuとsliderのtracking中も完了を処理し、最新要求を送る。
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                self?.complete(result, generation: generation, saving: saving ? percent : nil)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        work = item
        queue.async(execute: item)
    }

    private func complete(_ result: Result<BrightnessReading, Error>, generation: UInt64, saving percent: Int?) {
        guard generation == self.generation else { return }
        if case .success = result, let percent { defaults.set(percent, forKey: Self.savedKey) }
        if case let .adjusting(requested, last) = state, let percent, requested != percent {
            state = .adjusting(requested: requested, last: (try? result.get()) ?? last)
            perform(percent: requested, saving: true)
            return
        }
        switch result {
        case let .success(reading): state = .ready(reading)
        case let .failure(error): state = .failed(message: error.localizedDescription, last: state.reading)
        }
    }
}
