import Foundation
import CoreGraphics

struct Contact: Equatable {
    let id: Int
    let point: CGPoint
}

enum TouchReport {
    // SW4101Cの実機descriptor: 10接点×6 bytes、接点数、scan time。
    static func decode(_ bytes: [UInt8], bounds: CGRect) -> [Contact]? {
        guard bytes.count == 64, bytes[0] == 0x10, bytes[61] <= 10,
              bounds.width > 1, bounds.height > 1 else { return nil }
        var contacts: [Contact] = []
        var ids = Set<Int>()
        for index in 0..<Int(bytes[61]) {
            let offset = 1 + index * 6
            guard bytes[offset] & 1 != 0 else { continue }
            let id = Int(bytes[offset + 1])
            let x = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
            let y = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
            guard x <= 4095, y <= 4095, ids.insert(id).inserted else { return nil }
            contacts.append(Contact(id: id, point: CGPoint(
                x: bounds.minX + CGFloat(x) / 4095 * (bounds.width - 1),
                y: bounds.minY + CGFloat(y) / 4095 * (bounds.height - 1))))
        }
        return contacts
    }
}

enum TouchAction: Equatable {
    case move(CGPoint), down(CGPoint), drag(CGPoint), up(CGPoint)
    case scroll(CGPoint, Int32, Int32, UInt32)
}

struct TouchGesture {
    private(set) var singleFingerScroll = false
    private enum State {
        case idle
        case one(Int, CGPoint, CGPoint, Bool)
        case scroll(Set<Int>, CGPoint, CGPoint)
        case waitForRelease
    }
    private var state: State = .idle
    private var remainder = CGPoint.zero

    mutating func setSingleFingerScroll(_ enabled: Bool) -> [TouchAction] {
        let wasIdle: Bool
        if case .idle = state { wasIdle = true } else { wasIdle = false }
        let actions = cancel()
        singleFingerScroll = enabled
        if !wasIdle { state = .waitForRelease }
        return actions
    }

    mutating func cancel() -> [TouchAction] {
        defer { state = .idle; remainder = .zero }
        switch state {
        case let .one(_, _, last, true): return [.up(last)]
        case let .scroll(_, _, anchor): return [.scroll(anchor, 0, 0, 4)]
        default: return []
        }
    }

    mutating func update(_ contacts: [Contact]) -> [TouchAction] {
        if contacts.isEmpty {
            let actions: [TouchAction]
            if case let .one(_, _, last, dragging) = state {
                actions = dragging ? [.up(last)] : [.down(last), .up(last)]
            } else {
                actions = cancel()
            }
            state = .idle
            return actions
        }
        if case .waitForRelease = state { return [] }
        if contacts.count > 2 {
            let actions = cancel()
            state = .waitForRelease
            return actions
        }
        let center = contacts.count == 1 ? contacts[0].point : CGPoint(
            x: (contacts[0].point.x + contacts[1].point.x) / 2,
            y: (contacts[0].point.y + contacts[1].point.y) / 2)
        let ids = Set(contacts.map(\.id))
        if case let .scroll(previousIDs, previous, anchor) = state {
            guard previousIDs == ids else {
                let actions = cancel()
                state = .waitForRelease
                return actions
            }
            let deltaX = center.x - previous.x + remainder.x
            let deltaY = center.y - previous.y + remainder.y
            let x = Int32(deltaX.rounded()), y = Int32(deltaY.rounded())
            remainder = CGPoint(x: deltaX - CGFloat(x), y: deltaY - CGFloat(y))
            state = .scroll(ids, center, anchor)
            return x == 0 && y == 0 ? [] : [.scroll(anchor, y, x, 2)]
        }
        if contacts.count == 2 {
            let actions = cancel()
            state = .scroll(ids, center, center)
            return actions + [.move(center), .scroll(center, 0, 0, 1)]
        }
        let contact = contacts[0]
        switch state {
        case .idle:
            state = .one(contact.id, contact.point, contact.point, false)
            return [.move(contact.point)]
        case let .one(id, start, _, dragging):
            guard id == contact.id else {
                let actions = cancel()
                state = .waitForRelease
                return actions
            }
            let shouldDrag = dragging || hypot(contact.point.x - start.x, contact.point.y - start.y) >= 7
            if singleFingerScroll && shouldDrag {
                state = .scroll(ids, contact.point, start)
                return [.move(start), .scroll(start, 0, 0, 1)]
            }
            state = .one(id, start, contact.point, shouldDrag)
            if shouldDrag {
                return (dragging ? [] : [.down(start)]) + [.drag(contact.point)]
            }
            return [.move(contact.point)]
        case .scroll, .waitForRelease: return []
        }
    }
}
