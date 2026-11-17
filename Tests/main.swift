import Foundation
import CoreGraphics

let bounds = CGRect(x: -1920, y: 2160, width: 1920, height: 1080)
var packet = [UInt8](repeating: 0, count: 64)
packet[0] = 16; packet[1] = 1; packet[61] = 1
assert(TouchReport.decode(packet, bounds: bounds) == [Contact(id: 0, point: CGPoint(x: -1920, y: 2160))])
packet[3] = 255; packet[4] = 15; packet[5] = 255; packet[6] = 15
assert(TouchReport.decode(packet, bounds: bounds)?.first?.point == CGPoint(x: -1, y: 3239))
packet[4] = 16
assert(TouchReport.decode(packet, bounds: bounds) == nil)
assert(TouchReport.decode([16], bounds: bounds) == nil)
packet[4] = 15; packet[7] = 1; packet[61] = 2
assert(TouchReport.decode(packet, bounds: bounds) == nil) // 重複ID

let fixture = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
for line in fixture.split(separator: "\n") {
    let bytes = line.split(separator: " ").map { UInt8($0, radix: 16)! }
    let contacts = TouchReport.decode(bytes, bounds: bounds)
    assert(contacts != nil)
    assert(contacts!.allSatisfy { bounds.contains($0.point) })
}
let p = CGPoint(x: 100, y: 100), q = CGPoint(x: 110, y: 120)
var gesture = TouchGesture()
assert(gesture.update([Contact(id: 0, point: p)]) == [.move(p)])
assert(gesture.update([]) == [.down(p), .up(p)])
_ = gesture.update([Contact(id: 0, point: p)])
assert(gesture.update([Contact(id: 0, point: q)]) == [.down(p), .drag(q)])
assert(gesture.cancel() == [.up(q)])
_ = gesture.update([Contact(id: 0, point: p)])
let pair = [Contact(id: 0, point: p), Contact(id: 1, point: q)]
let center = CGPoint(x: 105, y: 110)
assert(gesture.update(pair) == [.move(center), .scroll(center, 0, 0, 1)])
let moved = pair.map { Contact(id: $0.id, point: CGPoint(x: $0.point.x, y: $0.point.y + 5)) }
assert(gesture.update(moved) == [.scroll(center, 5, 0, 2)])
assert(gesture.update([moved[0]]) == [.scroll(center, 0, 0, 4)])
assert(gesture.update([]).isEmpty) // スクロール後の残った指でクリックしない
_ = gesture.update([Contact(id: 0, point: p)])
_ = gesture.update([Contact(id: 0, point: q)])
assert(gesture.update([Contact(id: 9, point: q)]) == [.up(q)])
assert(gesture.update([]).isEmpty)
var singleScroll = TouchGesture()
assert(singleScroll.setSingleFingerScroll(true).isEmpty)
assert(singleScroll.singleFingerScroll)
assert(singleScroll.update([Contact(id: 0, point: p)]) == [.move(p)])
assert(singleScroll.update([]) == [.down(p), .up(p)])
_ = singleScroll.update([Contact(id: 0, point: p)])
assert(singleScroll.update([Contact(id: 0, point: q)]) == [.move(p), .scroll(p, 0, 0, 1)])
let r = CGPoint(x: q.x + 3, y: q.y + 5)
assert(singleScroll.update([Contact(id: 0, point: r)]) == [.scroll(p, 5, 3, 2)])
assert(singleScroll.update([]) == [.scroll(p, 0, 0, 4)]) // スワイプ後にクリックしない
assert(singleScroll.update(pair) == [.move(center), .scroll(center, 0, 0, 1)])
assert(singleScroll.update([]) == [.scroll(center, 0, 0, 4)])
_ = singleScroll.setSingleFingerScroll(false)
_ = singleScroll.update([Contact(id: 0, point: p)])
_ = singleScroll.update([Contact(id: 0, point: q)])
assert(singleScroll.setSingleFingerScroll(true) == [.up(q)])
assert(singleScroll.update([Contact(id: 0, point: r)]).isEmpty)
assert(singleScroll.update([]).isEmpty)
_ = singleScroll.update([Contact(id: 0, point: p)])
_ = singleScroll.update([Contact(id: 0, point: q)])
assert(singleScroll.setSingleFingerScroll(false) == [.scroll(p, 0, 0, 4)])
assert(singleScroll.update([]).isEmpty) // モード変更時に指を離してもクリックしない
assert(!singleScroll.singleFingerScroll)
print("PASS: report validation, hardware reports, coordinates, tap, drag, cancellation, one/two-finger scroll, mode changes")

func expectBrightnessError(_ operation: () throws -> Void) {
    do { try operation(); assertionFailure("Expected brightness error") }
    catch { assert(error is BrightnessError) }
}

let reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 61, 0xfd]
let brightnessReading = BrightnessReading(current: 61, maximum: 100)!
assert(try! BrightnessPacket.decode(reply) == brightnessReading)
assert(try! BrightnessPacket.decode(reply + [0xff]) == brightnessReading) // 12 byte目は余白
expectBrightnessError { _ = try BrightnessPacket.decode(Array(reply.prefix(10))) }
expectBrightnessError { _ = try BrightnessPacket.decode(reply + [0, 0]) }
for (index, value): (Int, UInt8) in [(0, 0x6f), (1, 0x87), (2, 1), (3, 1), (4, 0x12), (5, 1),
                                    (7, 0), (9, 101)] {
    var invalid = reply
    invalid[index] = value
    invalid[10] = invalid.prefix(10).reduce(0x50, ^)
    expectBrightnessError { _ = try BrightnessPacket.decode(invalid) }
}
var badChecksum = reply
badChecksum[10] ^= 1
expectBrightnessError { _ = try BrightnessPacket.decode(badChecksum) }
assert(BrightnessReading(current: 0, maximum: 100)!.percent == 0)
assert(BrightnessReading(current: 100, maximum: 100)!.percent == 100)
assert(BrightnessReading(current: 1, maximum: 0) == nil)
assert(BrightnessReading(current: 101, maximum: 100) == nil)
let wideRange = BrightnessReading(current: 156, maximum: 255)!
assert(wideRange.percent == 61)
assert(try! wideRange.value(for: 61) == 156)
assert(try! wideRange.value(for: 0) == 0)
assert(try! wideRange.value(for: 100) == 255)
assert(try! BrightnessReading(current: 0, maximum: .max)!.value(for: 100) == .max)
expectBrightnessError { _ = try wideRange.value(for: -1) }
expectBrightnessError { _ = try wideRange.value(for: 101) }
assert(BrightnessPacket.read.count == 4 && BrightnessPacket.read.reduce(0x6e ^ 0x51, ^) == 0)
for value: UInt16 in [0, 100, 168, .max] {
    let bytes = BrightnessPacket.set(value)
    assert(bytes.count == 6 && bytes.reduce(0x6e ^ 0x51, ^) == 0)
    assert(UInt16(bytes[3]) << 8 | UInt16(bytes[4]) == value)
}
assert(BrightnessPacket.set(168).last == 0) // checksumが0でも省略しない
assert(try! savedBrightnessPercent(nil) == nil)
assert(try! savedBrightnessPercent(0) == 0)
assert(try! savedBrightnessPercent(100) == 100)
for object: Any in [true, -1, 101, 61.5, "61", Double.nan, Int.max] {
    expectBrightnessError { _ = try savedBrightnessPercent(object) }
}

final class FakeBrightnessCommunication {
    struct Step {
        let displayID: CGDirectDisplayID
        let percent: Int?
        let result: Result<BrightnessReading, Error>
    }

    private let steps: [Step]
    private let condition = NSCondition()
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    private var active = false

    init(_ steps: [Step]) { self.steps = steps }

    var requestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    func communicate(displayID: CGDirectDisplayID, percent: Int?) throws -> BrightnessReading {
        assert(!Thread.isMainThread)
        condition.lock()
        assert(!active && count < steps.count, "Only one DDC request may be in flight")
        let step = steps[count]
        assert(step.displayID == displayID && step.percent == percent, "Unexpected DDC request")
        active = true
        count += 1
        condition.broadcast()
        condition.unlock()
        assert(release.wait(timeout: .now() + 5) == .success, "Test did not release DDC request")
        condition.lock()
        active = false
        condition.unlock()
        return try step.result.get()
    }

    func waitForRequest(_ expected: Int) {
        let deadline = Date(timeIntervalSinceNow: 3)
        condition.lock()
        defer { condition.unlock() }
        while count < expected {
            assert(condition.wait(until: deadline), "DDC request did not start")
        }
        assert(count == expected)
    }

    func finishRequest() { release.signal() }
}

let trackingMode = RunLoop.Mode("NSEventTrackingRunLoopMode")
CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: trackingMode.rawValue as CFString))
let trackingTimer = Timer(timeInterval: 0.01, repeats: true) { _ in }
RunLoop.main.add(trackingTimer, forMode: trackingMode)
defer { trackingTimer.invalidate() }
func trackUntil(_ predicate: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !predicate() && Date() < deadline {
        _ = RunLoop.main.run(mode: trackingMode, before: Date(timeIntervalSinceNow: 0.01))
    }
    assert(predicate(), "Completion must run during event tracking")
}
func reading(_ percent: UInt16) -> Result<BrightnessReading, Error> {
    .success(BrightnessReading(current: percent, maximum: 100)!)
}

let defaultsSuite = "KDTouch.selfcheck.\(UUID().uuidString)"
let brightnessDefaults = UserDefaults(suiteName: defaultsSuite)!
defer { brightnessDefaults.removePersistentDomain(forName: defaultsSuite) }
let fakeBrightness = FakeBrightnessCommunication([
    .init(displayID: 7, percent: nil, result: reading(61)),
    .init(displayID: 7, percent: 10, result: reading(10)),
    .init(displayID: 7, percent: 90, result: reading(90)),
    .init(displayID: 7, percent: 100, result: .failure(BrightnessError.readbackMismatch)),
    .init(displayID: 7, percent: nil, result: reading(90)),
    .init(displayID: 7, percent: 20, result: .failure(BrightnessError.readbackMismatch)),
    .init(displayID: 7, percent: 30, result: .failure(BrightnessError.readbackMismatch)),
    .init(displayID: 7, percent: 35, result: reading(35)),
    .init(displayID: 7, percent: 40, result: reading(40)),
    .init(displayID: 8, percent: 35, result: reading(35)),
    .init(displayID: 8, percent: 0, result: reading(0)),
    .init(displayID: 8, percent: nil, result: reading(71)),
])
let brightnessController = BrightnessController(defaults: brightnessDefaults,
                                               communicate: fakeBrightness.communicate)
var displayedBrightness: [Int?] = []
brightnessController.onChange = { state in
    assert(Thread.isMainThread)
    displayedBrightness.append(state.displayedPercent)
}
brightnessController.connect(displayID: 7)
fakeBrightness.waitForRequest(1)
brightnessController.set(percent: 50)
assert(fakeBrightness.requestCount == 1)
fakeBrightness.finishRequest()
trackUntil { if case .ready = brightnessController.state { return true }; return false }
assert(brightnessController.state.displayedPercent == 61)
assert(brightnessDefaults.object(forKey: BrightnessController.savedKey) == nil)
brightnessController.set(percent: -1)
brightnessController.set(percent: 101)
assert(brightnessController.state.displayedPercent == 61 && fakeBrightness.requestCount == 1)

brightnessController.set(percent: 10)
fakeBrightness.waitForRequest(2)
for percent in [20, 40, 90] {
    brightnessController.set(percent: percent)
    assert(brightnessController.state.displayedPercent == percent)
}
brightnessController.refresh()
assert(fakeBrightness.requestCount == 2)
let updatesAt90 = displayedBrightness.count
fakeBrightness.finishRequest()
trackUntil { fakeBrightness.requestCount == 3 }
assert(brightnessController.state.displayedPercent == 90)
assert(brightnessController.state.reading?.percent == 10)
assert(displayedBrightness.dropFirst(updatesAt90).allSatisfy { $0 == 90 })
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 10)
fakeBrightness.finishRequest()
trackUntil { if case .ready = brightnessController.state { return true }; return false }
assert(brightnessController.state.reading?.percent == 90)
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 90)

brightnessController.set(percent: 100)
fakeBrightness.waitForRequest(4)
fakeBrightness.finishRequest()
trackUntil { if case .failed = brightnessController.state { return true }; return false }
assert(brightnessController.state.reading?.percent == 90)
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 90)
brightnessController.refresh()
fakeBrightness.waitForRequest(5)
fakeBrightness.finishRequest()
trackUntil { if case .ready = brightnessController.state { return true }; return false }
brightnessController.set(percent: 20)
fakeBrightness.waitForRequest(6)
brightnessController.set(percent: 25)
brightnessController.set(percent: 30)
let updatesAt30 = displayedBrightness.count
fakeBrightness.finishRequest()
trackUntil { fakeBrightness.requestCount == 7 }
assert(brightnessController.state.displayedPercent == 30)
assert(brightnessController.state.reading?.percent == 90)
assert(displayedBrightness.dropFirst(updatesAt30).allSatisfy { $0 == 30 })
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 90)
brightnessController.set(percent: 35)
let updatesAt35 = displayedBrightness.count
fakeBrightness.finishRequest()
trackUntil { fakeBrightness.requestCount == 8 }
assert(brightnessController.state.displayedPercent == 35)
assert(displayedBrightness.dropFirst(updatesAt35).allSatisfy { $0 == 35 })
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 90)
fakeBrightness.finishRequest()
trackUntil { if case .ready = brightnessController.state { return true }; return false }
assert(brightnessController.state.reading?.percent == 35)
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 35)

brightnessController.set(percent: 40)
fakeBrightness.waitForRequest(9)
brightnessController.set(percent: 50)
brightnessController.connect(displayID: nil)
assert(brightnessController.state.displayedPercent == nil)
brightnessController.set(percent: 60)
brightnessController.connect(displayID: 8)
let updatesBeforeStaleResult = displayedBrightness.count
fakeBrightness.finishRequest()
fakeBrightness.waitForRequest(10)
_ = RunLoop.main.run(mode: trackingMode, before: Date(timeIntervalSinceNow: 0.02))
assert(displayedBrightness.count == updatesBeforeStaleResult)
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 35)
fakeBrightness.finishRequest()
trackUntil { if case .ready = brightnessController.state { return true }; return false }
assert(brightnessController.state.reading?.percent == 35)
brightnessController.set(percent: 0)
fakeBrightness.waitForRequest(11)
brightnessController.set(percent: 0)
fakeBrightness.finishRequest()
trackUntil { if case .ready = brightnessController.state { return true }; return false }
assert(brightnessController.state.reading?.percent == 0)
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 0)
brightnessController.refresh()
fakeBrightness.waitForRequest(12)
fakeBrightness.finishRequest()
trackUntil { if case .ready = brightnessController.state { return true }; return false }
assert(brightnessController.state.reading?.percent == 71)
assert(try! savedBrightnessPercent(brightnessDefaults.object(forKey: BrightnessController.savedKey)) == 0)
brightnessController.connect(displayID: 8)
assert(fakeBrightness.requestCount == 12)
print("PASS: brightness packets, validation, percentage boundaries, saved values, continuous latest-value writes, display stability, failure preservation, stale-result rejection, event-tracking completion")
