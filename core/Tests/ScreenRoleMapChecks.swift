// Compiled with ScreenRoleMap.swift and run by the Nix package checkPhase.
import CoreGraphics

@main
enum ScreenRoleMapChecks {
    static func main() {
        let main  = AttachedDisplay(uuid: "M", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isMain: true)
        let right = AttachedDisplay(uuid: "R", name: "LG", frame: CGRect(x: 1728, y: -200, width: 2560, height: 1440), isMain: false)
        let left  = AttachedDisplay(uuid: "L", name: "Dell", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isMain: false)
        let above = AttachedDisplay(uuid: "A", name: "iPad", frame: CGRect(x: 200, y: -1200, width: 1366, height: 1024), isMain: false)
        let farRight = AttachedDisplay(uuid: "FR", name: "iPad 2", frame: CGRect(x: 4300, y: 0, width: 1366, height: 1024), isMain: false)

        // The educated guess.
        let guessed = ScreenRoleMap.assign(explicit: [:], displays: [left, main, right, above, farRight])
        precondition(guessed == ["M": .primary, "R": .secondary, "L": .tertiary, "A": .auxPrimary, "FR": .auxSecondary], "\(guessed)")

        // A lone laptop is primary; two displays get primary and secondary/tertiary by side.
        precondition(ScreenRoleMap.assign(explicit: [:], displays: [main]) == ["M": .primary])
        precondition(ScreenRoleMap.assign(explicit: [:], displays: [main, left]) == ["M": .primary, "L": .tertiary])

        // An explicit choice wins and displaces the guess; no role is held twice.
        let swapped = ScreenRoleMap.assign(explicit: ["L": .secondary], displays: [left, main, right])
        precondition(swapped["L"] == .secondary && swapped["M"] == .primary && swapped["R"] == .tertiary, "\(swapped)")
        let allRoles = swapped.values.map(\.rawValue).sorted()
        precondition(Set(allRoles).count == allRoles.count)

        // Explicit primary elsewhere: the main display takes the next free role.
        let movedPrimary = ScreenRoleMap.assign(explicit: ["R": .primary], displays: [main, right])
        precondition(movedPrimary == ["R": .primary, "M": .secondary], "\(movedPrimary)")

        // A stale explicit entry for a detached display changes nothing.
        precondition(ScreenRoleMap.assign(explicit: ["gone": .secondary], displays: [main, right]) == ["M": .primary, "R": .secondary])

        // More displays than roles: the farthest stay unmapped rather than share.
        let seven = (0..<7).map { i in AttachedDisplay(uuid: "d\(i)", name: "", frame: CGRect(x: CGFloat(i) * 1000, y: 0, width: 900, height: 900), isMain: i == 0) }
        let many = ScreenRoleMap.assign(explicit: [:], displays: seven)
        precondition(many.count == ScreenRole.allCases.count && many["d6"] == nil, "\(many)")

        // Setting a role takes it from whoever had it.
        let set = ScreenRoleMap.setting(.secondary, for: "L", in: ["R": .secondary, "M": .primary])
        precondition(set == ["L": .secondary, "M": .primary], "\(set)")

        // Wire names match the brain's.
        precondition(ScreenRole.allCases.map(\.rawValue) == ["primary", "secondary", "tertiary", "aux-primary", "aux-secondary", "aux-tertiary"])
        print("Screen role map checks passed")
    }
}
