import Foundation
import CoreGraphics

// MARK: - FlatRect: CGRect wire format as {"x":0,"y":0,"w":800,"h":600}

/// Codable wrapper for CGRect that serializes as flat {x,y,w,h} instead of
/// the system's nested {origin:{x,y},size:{width,height}} format.
struct FlatRect: Codable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.w = rect.size.width
        self.h = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - WindowInfo

struct WindowInfo: Sendable {
    let windowId: UInt32
    let pid: Int32
    let title: String?
    let appName: String?
    let bundleId: String?
    let subrole: String?
    let isDialog: Bool
    let isFixedSize: Bool
    let hasCloseButton: Bool
    let hasFullscreenButton: Bool
    let frame: CGRect
}

extension WindowInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case windowId, pid, title, appName, bundleId, subrole
        case isDialog, isFixedSize, hasCloseButton, hasFullscreenButton, frame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowId = try c.decode(UInt32.self, forKey: .windowId)
        pid = try c.decode(Int32.self, forKey: .pid)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
        isDialog = try c.decode(Bool.self, forKey: .isDialog)
        isFixedSize = try c.decode(Bool.self, forKey: .isFixedSize)
        hasCloseButton = try c.decode(Bool.self, forKey: .hasCloseButton)
        hasFullscreenButton = try c.decode(Bool.self, forKey: .hasFullscreenButton)
        frame = try c.decode(FlatRect.self, forKey: .frame).cgRect
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windowId, forKey: .windowId)
        try c.encode(pid, forKey: .pid)
        try c.encode(title, forKey: .title)
        try c.encode(appName, forKey: .appName)
        try c.encode(bundleId, forKey: .bundleId)
        try c.encode(subrole, forKey: .subrole)
        try c.encode(isDialog, forKey: .isDialog)
        try c.encode(isFixedSize, forKey: .isFixedSize)
        try c.encode(hasCloseButton, forKey: .hasCloseButton)
        try c.encode(hasFullscreenButton, forKey: .hasFullscreenButton)
        try c.encode(FlatRect(frame), forKey: .frame)
    }
}

// MARK: - Shared IPC Types

struct ScreenInfo: Sendable {
    let screenId: Int
    let frame: CGRect
}

extension ScreenInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case screenId, frame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenId = try c.decode(Int.self, forKey: .screenId)
        frame = try c.decode(FlatRect.self, forKey: .frame).cgRect
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screenId, forKey: .screenId)
        try c.encode(FlatRect(frame), forKey: .frame)
    }
}

struct FrameAssignment: Sendable {
    let windowId: UInt32
    let pid: Int32
    let frame: CGRect
}

extension FrameAssignment: Codable {
    private enum CodingKeys: String, CodingKey {
        case windowId, pid, frame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowId = try c.decode(UInt32.self, forKey: .windowId)
        pid = try c.decode(Int32.self, forKey: .pid)
        frame = try c.decode(FlatRect.self, forKey: .frame).cgRect
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windowId, forKey: .windowId)
        try c.encode(pid, forKey: .pid)
        try c.encode(FlatRect(frame), forKey: .frame)
    }
}

struct HotkeySpec: Codable, Sendable {
    let id: Int
    let keyCode: UInt32
    let modifiers: UInt32
}

// MARK: - Events (Swift -> Haskell)

enum IPCEvent: Encodable, Sendable {
    case windowCreated(WindowInfo)
    case windowDestroyed(windowId: UInt32)
    case windowFrameChanged(windowId: UInt32, frame: CGRect)
    case frontAppChanged(pid: Int32)
    case screensChanged(screens: [ScreenInfo])
    case hotkeyPressed(hotkeyId: Int)
    case mouseEnteredWindow(windowId: UInt32, pid: Int32)
    case ready

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        switch self {
        case .windowCreated(let info):
            try container.encode("window-created", forKey: .event)
            try container.encode(info.windowId, forKey: .windowId)
            try container.encode(info.pid, forKey: .pid)
            try container.encode(info.title, forKey: .title)
            try container.encode(info.appName, forKey: .appName)
            try container.encode(info.bundleId, forKey: .bundleId)
            try container.encode(info.subrole, forKey: .subrole)
            try container.encode(info.isDialog, forKey: .isDialog)
            try container.encode(info.isFixedSize, forKey: .isFixedSize)
            try container.encode(info.hasCloseButton, forKey: .hasCloseButton)
            try container.encode(info.hasFullscreenButton, forKey: .hasFullscreenButton)
            try container.encode(FlatRect(info.frame), forKey: .frame)
        case .windowDestroyed(let windowId):
            try container.encode("window-destroyed", forKey: .event)
            try container.encode(windowId, forKey: .windowId)
        case .windowFrameChanged(let windowId, let frame):
            try container.encode("window-frame-changed", forKey: .event)
            try container.encode(windowId, forKey: .windowId)
            try container.encode(FlatRect(frame), forKey: .frame)
        case .frontAppChanged(let pid):
            try container.encode("front-app-changed", forKey: .event)
            try container.encode(pid, forKey: .pid)
        case .screensChanged(let screens):
            try container.encode("screens-changed", forKey: .event)
            try container.encode(screens, forKey: .screens)
        case .hotkeyPressed(let hotkeyId):
            try container.encode("hotkey-pressed", forKey: .event)
            try container.encode(hotkeyId, forKey: .hotkeyId)
        case .mouseEnteredWindow(let windowId, let pid):
            try container.encode("mouse-entered-window", forKey: .event)
            try container.encode(windowId, forKey: .windowId)
            try container.encode(pid, forKey: .pid)
        case .ready:
            try container.encode("ready", forKey: .event)
        }
    }
}

// MARK: - Commands (Haskell -> Swift)

enum IPCCommand: Decodable, Sendable {
    case setFrames(frames: [FrameAssignment])
    case focusWindow(windowId: UInt32, pid: Int32)
    case hideWindows(windowIds: [UInt32])
    case showWindows(windowIds: [UInt32])
    case queryWindows
    case queryScreens
    case registerHotkeys(hotkeys: [HotkeySpec])
    case closeWindow(windowId: UInt32, pid: Int32)
    case setWorkspaceIndicator(tag: String)

    private enum CmdType: String, Decodable {
        case setFrames = "set-frames"
        case focusWindow = "focus-window"
        case hideWindows = "hide-windows"
        case showWindows = "show-windows"
        case queryWindows = "query-windows"
        case queryScreens = "query-screens"
        case registerHotkeys = "register-hotkeys"
        case closeWindow = "close-window"
        case setWorkspaceIndicator = "set-workspace-indicator"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let cmd = try container.decode(CmdType.self, forKey: .cmd)
        switch cmd {
        case .setFrames:
            let frames = try container.decode([FrameAssignment].self, forKey: .frames)
            self = .setFrames(frames: frames)
        case .focusWindow:
            let windowId = try container.decode(UInt32.self, forKey: .windowId)
            let pid = try container.decode(Int32.self, forKey: .pid)
            self = .focusWindow(windowId: windowId, pid: pid)
        case .hideWindows:
            let windowIds = try container.decode([UInt32].self, forKey: .windowIds)
            self = .hideWindows(windowIds: windowIds)
        case .showWindows:
            let windowIds = try container.decode([UInt32].self, forKey: .windowIds)
            self = .showWindows(windowIds: windowIds)
        case .queryWindows:
            self = .queryWindows
        case .queryScreens:
            self = .queryScreens
        case .registerHotkeys:
            let hotkeys = try container.decode([HotkeySpec].self, forKey: .hotkeys)
            self = .registerHotkeys(hotkeys: hotkeys)
        case .closeWindow:
            let windowId = try container.decode(UInt32.self, forKey: .windowId)
            let pid = try container.decode(Int32.self, forKey: .pid)
            self = .closeWindow(windowId: windowId, pid: pid)
        case .setWorkspaceIndicator:
            let tag = try container.decode(String.self, forKey: .tag)
            self = .setWorkspaceIndicator(tag: tag)
        }
    }
}

// MARK: - Query Responses

struct QueryWindowsResponse: Encodable, Sendable {
    let response: String = "windows"
    let windows: [WindowInfo]
}

struct QueryScreensResponse: Encodable, Sendable {
    let response: String = "screens"
    let screens: [ScreenInfo]
}

// MARK: - Dynamic Coding Key

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static let event = DynamicCodingKey(stringValue: "event")!
    static let cmd = DynamicCodingKey(stringValue: "cmd")!
    static let windowId = DynamicCodingKey(stringValue: "windowId")!
    static let windowIds = DynamicCodingKey(stringValue: "windowIds")!
    static let pid = DynamicCodingKey(stringValue: "pid")!
    static let title = DynamicCodingKey(stringValue: "title")!
    static let appName = DynamicCodingKey(stringValue: "appName")!
    static let bundleId = DynamicCodingKey(stringValue: "bundleId")!
    static let subrole = DynamicCodingKey(stringValue: "subrole")!
    static let isDialog = DynamicCodingKey(stringValue: "isDialog")!
    static let isFixedSize = DynamicCodingKey(stringValue: "isFixedSize")!
    static let hasCloseButton = DynamicCodingKey(stringValue: "hasCloseButton")!
    static let hasFullscreenButton = DynamicCodingKey(stringValue: "hasFullscreenButton")!
    static let frame = DynamicCodingKey(stringValue: "frame")!
    static let frames = DynamicCodingKey(stringValue: "frames")!
    static let screens = DynamicCodingKey(stringValue: "screens")!
    static let hotkeyId = DynamicCodingKey(stringValue: "hotkeyId")!
    static let hotkeys = DynamicCodingKey(stringValue: "hotkeys")!
    static let tag = DynamicCodingKey(stringValue: "tag")!
}
