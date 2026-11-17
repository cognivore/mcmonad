// AI-generated file: model claude-opus-5-5; reasoning effort unavailable (not exposed by the harness).
//
// The macOS interpreter of awake: it observes the Mac, registers the guard,
// and renders the views Rust words. It decides nothing.

import AppKit
import AwakeFFI
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import ServiceManagement
import SwiftUI

/// Reads the Mac. Each value is a mechanical reading; Rust decides what it means.
final class MacReader: Mac, @unchecked Sendable {
    let model: Model?
    init(model: Model?) { self.model = model }

    func observe() async throws -> MacState {
        let (battery, onAc) = Self.power()
        return MacState(
            battery: battery,
            onAc: onAc,
            thermal: Self.thermal(),
            lidClosed: Self.lidClosed(),
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            locked: Self.locked()
        )
    }

    func render(view: MenuState) {
        guard let model else { return }
        Task { @MainActor in model.view = view }
    }

    static func power() -> (UInt8?, Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let onAc = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (UInt8(clamping: now * 100 / max), onAc)
        }
        return (nil, onAc)
    }

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }

    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    static func locked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

@MainActor @Observable
final class Model {
    var view = MenuState(phase: .idle, line: "Not running", warning: nil, holders: [])
    var guardState = "checking the guard…"
    var error: String?
    var awake: Awake?

    let daemon = SMAppService.daemon(plistName: "de.memorici.awake.guard.plist")

    func boot() {
        awake = Awake(mac: MacReader(model: self))
        registerGuard()
        Task { if let a = awake { view = await a.idleMenu() } }
    }

    func registerGuard() {
        if daemon.status == .notRegistered || daemon.status == .notFound {
            do { try daemon.register() } catch { guardState = "the guard could not register: \(error.localizedDescription)" }
        }
        guardState = switch daemon.status {
        case .enabled: "guard: allowed"
        case .requiresApproval: "guard: needs your OK in Login Items"
        case .notRegistered: "guard: not registered"
        case .notFound: "guard: not found in the app"
        @unknown default: "guard: unknown"
        }
    }

    func start(minutes: UInt32, floor: UInt8 = 20) {
        guard let awake else { return }
        error = nil
        Task {
            do { try await awake.start(minutes: minutes, floor: floor) } catch { self.error = "\(error)" }
        }
    }

    func stop() {
        guard let awake else { return }
        Task { await awake.stop() }
    }

    /// awake://start?minutes=60&floor=20 and awake://stop, from the `awake` command.
    func open(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func number(_ name: String) -> Int? { items.first { $0.name == name }?.value.flatMap(Int.init) }
        switch url.host {
        case "start": start(minutes: UInt32(clamping: number("minutes") ?? 60), floor: UInt8(clamping: number("floor") ?? 20))
        case "stop": stop()
        default: error = "unknown request \(url.absoluteString)"
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: Model?
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { for url in urls { Delegate.model?.open(url) } }
    }
}

struct Menu: SwiftUI.View {
    @Bindable var model: Model

    var body: some SwiftUI.View {
        Text(model.view.line)
        if let w = model.view.warning { Text("⚠︎ \(w)") }
        if let e = model.error { Text("⚠︎ \(e)") }
        Divider()
        if model.view.phase == .running {
            Button("Stop") { model.stop() }
        } else {
            Button("Keep awake 30 minutes") { model.start(minutes: 30) }
            Button("Keep awake 1 hour") { model.start(minutes: 60) }
            Button("Keep awake 2 hours") { model.start(minutes: 120) }
            Button("Keep awake 4 hours") { model.start(minutes: 240) }
        }
        if !model.view.holders.isEmpty {
            Divider()
            Text("Also keeping the Mac awake:")
            ForEach(model.view.holders, id: \.self) { h in Text("\(h.process) (pid \(h.pid)): \(h.what)") }
        }
        Divider()
        Text(model.guardState)
        if model.daemon.status == .requiresApproval {
            Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}

struct AwakeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @State private var model: Model

    init() {
        let m = Model()
        _model = State(initialValue: m)
        Delegate.model = m
        m.boot()
    }

    var body: some Scene {
        MenuBarExtra {
            Menu(model: model)
        } label: {
            Image(systemName: model.view.phase == .running ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
    }
}

/// Selftest interpreter: a fixed Mac, so no real lock, display or lease is touched.
final class ScriptedMac: Mac, @unchecked Sendable {
    func observe() async throws -> MacState {
        MacState(battery: 50, onAc: false, thermal: .nominal, lidClosed: false, displayAsleep: false, locked: false)
    }
    func render(view: MenuState) {}
}

@MainActor
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            Task.detached { exit(await selftest()) }
            dispatchMain()
        }
        AwakeApp.main()
    }
}

/// Every crossing, against the real bundle binary. Exit status = number of failures.
func selftest() async -> Int32 {
    var failures: Int32 = 0
    func check(_ name: String, _ ok: Bool, _ got: Any) {
        print(ok ? "PASS" : "FAIL", name, "->", String(reflecting: got))
        if !ok { failures += 1 }
    }
    let awake = Awake(mac: ScriptedMac())
    let fine = await Result { try await awake.check(minutes: 30, floor: 20) }
    check("a valid request is described", (try? fine.get())?.hasPrefix("0:30 left · 50%") == true, fine)
    let low = await Result { try await awake.check(minutes: 30, floor: 60) }
    check("below the floor is refused", { if case .failure(AwakeError.Refused) = low { true } else { false } }(), low)
    let long = await Result { try await awake.check(minutes: 24 * 60, floor: 20) }
    check("too long is refused", { if case .failure(AwakeError.Refused) = long { true } else { false } }(), long)
    let real = try? await MacReader(model: nil).observe()
    check("the real Mac can be read", real != nil, real as Any)
    let idle = await awake.idleMenu()
    check("the idle view renders", idle.phase == .idle, idle)
    return failures
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
