import Foundation

/// The user's explicit display → role choices, kept in this app's
/// defaults (`com.mcmonad.core`, key `screenRoles`) — per-machine device
/// state like the display arrangement itself, not window-management
/// configuration. Only uuids and role names are stored.
@MainActor
final class ScreenRoles {
    private static let key = "screenRoles"

    var explicit: [String: ScreenRole] {
        let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        return raw.reduce(into: [:]) { acc, kv in
            if let role = ScreenRole(rawValue: kv.value) { acc[kv.key] = role }
        }
    }

    func set(_ role: ScreenRole, for uuid: String) {
        let next = ScreenRoleMap.setting(role, for: uuid, in: explicit)
        UserDefaults.standard.set(next.mapValues(\.rawValue), forKey: Self.key)
    }
}
