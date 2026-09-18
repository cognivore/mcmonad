import Foundation
import CoreGraphics

/// What a display is *for*. The brain's workspace affinity is expressed in
/// these, never in left or right; this file decides which attached display
/// carries which role. Raw values are the wire spelling the brain parses.
enum ScreenRole: String, CaseIterable, Codable, Sendable {
    case primary
    case secondary
    case tertiary
    case auxPrimary = "aux-primary"
    case auxSecondary = "aux-secondary"
    case auxTertiary = "aux-tertiary"

    var label: String {
        switch self {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        case .tertiary: return "Tertiary"
        case .auxPrimary: return "Aux primary"
        case .auxSecondary: return "Aux secondary"
        case .auxTertiary: return "Aux tertiary"
        }
    }
}

/// One attached display as the role map sees it. `frame` is in screen
/// coordinates (origin top-left, points), the same space the brain gets.
struct AttachedDisplay: Equatable, Sendable {
    let uuid: String
    let name: String
    let frame: CGRect
    /// macOS's main display (the one with the menu bar).
    let isMain: Bool
}

/// Pure: explicit mappings plus the educated guess for the rest.
enum ScreenRoleMap {
    /// A role for every attached display. Explicit mappings (uuid → role)
    /// win; unmapped displays are guessed from the arrangement: the main
    /// display is primary, the nearest display to its right is secondary,
    /// the nearest to its left tertiary, displays above or below it are
    /// auxiliary, and anything still unplaced takes the first free role.
    /// No role is given to two displays.
    static func assign(explicit: [String: ScreenRole], displays: [AttachedDisplay]) -> [String: ScreenRole] {
        var result: [String: ScreenRole] = [:]
        var free = ScreenRole.allCases
        // Explicit first, one display per role: a role named twice goes to
        // the display whose uuid sorts first, so the outcome is stable.
        for d in displays.sorted(by: { $0.uuid < $1.uuid }) {
            guard let role = explicit[d.uuid], free.contains(role) else { continue }
            result[d.uuid] = role
            free.removeAll { $0 == role }
        }
        let main = displays.first { $0.isMain } ?? displays.first
        let anchor = main.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        let unmapped = displays
            .filter { result[$0.uuid] == nil }
            .sorted { distance($0.frame, anchor) < distance($1.frame, anchor) }
        for d in unmapped {
            let wanted: ScreenRole
            if d.isMain || d.uuid == main?.uuid {
                wanted = .primary
            } else {
                let dx = d.frame.midX - anchor.x
                let dy = d.frame.midY - anchor.y
                if abs(dx) >= abs(dy) {
                    wanted = dx > 0 ? .secondary : .tertiary
                } else {
                    wanted = .auxPrimary
                }
            }
            let role = free.contains(wanted) ? wanted : free.first
            guard let role else { break }   // more displays than roles: the rest stay unmapped
            result[d.uuid] = role
            free.removeAll { $0 == role }
        }
        return result
    }

    /// The explicit map with `uuid` given `role`, taken away from any other
    /// display that held it.
    static func setting(_ role: ScreenRole, for uuid: String, in explicit: [String: ScreenRole]) -> [String: ScreenRole] {
        var next = explicit.filter { $0.value != role }
        next[uuid] = role
        return next
    }

    private static func distance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = frame.midX - point.x
        let dy = frame.midY - point.y
        return dx * dx + dy * dy
    }
}
