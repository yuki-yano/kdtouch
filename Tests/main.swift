import Foundation

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
print("PASS: report validation, captured hardware reports, coordinate bounds, tap, drag, cancellation, two-finger scroll")
