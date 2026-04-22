import CoreGraphics
import Foundation
import os

// MARK: - Window query using SkyLight iterator API

enum SkyLightQuery {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "SkyLightQuery"
    )

    /// Enumerates all visible, top-level windows via the SkyLight iterator API.
    ///
    /// Filtering rules (matching OmniWM):
    /// - `parentId == 0` (top-level only)
    /// - `level` in {0, 3, 8} (normal, floating utility, overlay)
    /// - Visible: `attributes & 0x2 != 0` OR tag bit 54 set
    /// - Document: `tags & 0x1 != 0` OR (floating `tags & 0x2` AND modal `tags & 0x8000_0000`)
    static func queryAllVisibleWindows() -> [WindowSnapshot] {
        guard let skyLight = SkyLight.shared else {
            logger.error("SkyLight not available for window query")
            return []
        }

        guard skyLight.hasIteratorSupport else {
            logger.error("SkyLight iterator symbols not available")
            return []
        }

        let cid = skyLight.getMainConnectionID()
        guard cid != 0 else {
            logger.warning("SkyLight main connection ID is 0")
            return []
        }

        let emptyArray = [] as CFArray
        guard let query = skyLight.queryWindows(
            connectionId: cid,
            windowArray: emptyArray,
            flags: 0
        ) else {
            logger.error("SLSWindowQueryWindows returned nil")
            return []
        }
        defer { skyLight.releaseCF(query) }

        guard let iterator = skyLight.queryResultCopyWindows(query) else {
            logger.error("SLSWindowQueryResultCopyWindows returned nil")
            return []
        }
        defer { skyLight.releaseCF(iterator) }

        var results: [WindowSnapshot] = []

        while skyLight.iteratorAdvance(iterator) {
            guard let parentId = skyLight.iteratorGetParentID(iterator),
                  parentId == 0
            else { continue }

            guard let level = skyLight.iteratorGetLevel(iterator),
                  level == 0 || level == 3 || level == 8
            else { continue }

            guard let tags = skyLight.iteratorGetTags(iterator),
                  let attributes = skyLight.iteratorGetAttributes(iterator)
            else { continue }

            // Visibility check
            let hasVisibleAttribute = (attributes & 0x2) != 0
            let hasTagBit54 = (tags & 0x0040_0000_0000_0000) != 0
            guard hasVisibleAttribute || hasTagBit54 else { continue }

            // Document/modal check
            let isDocument = (tags & 0x1) != 0
            let isFloating = (tags & 0x2) != 0
            let isModal = (tags & 0x8000_0000) != 0
            guard isDocument || (isFloating && isModal) else { continue }

            guard let windowId = skyLight.iteratorGetWindowID(iterator),
                  let pid = skyLight.iteratorGetPID(iterator),
                  let bounds = skyLight.iteratorGetBounds(iterator)
            else { continue }

            results.append(WindowSnapshot(
                windowId: windowId,
                pid: pid,
                frame: bounds,
                level: level,
                tags: tags,
                attributes: attributes,
                parentId: parentId
            ))
        }

        return results
    }

    /// Query a single window by ID. Returns nil if not found.
    static func queryWindow(_ windowId: UInt32) -> WindowSnapshot? {
        guard let skyLight = SkyLight.shared else { return nil }
        guard skyLight.hasIteratorSupport else { return nil }

        let cid = skyLight.getMainConnectionID()
        guard cid != 0 else { return nil }

        var widValue = Int32(windowId)
        guard let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue) else {
            return nil
        }
        let windowArray = [widNumber] as CFArray

        guard let query = skyLight.queryWindows(
            connectionId: cid,
            windowArray: windowArray,
            flags: 1
        ) else { return nil }
        defer { skyLight.releaseCF(query) }

        guard let iterator = skyLight.queryResultCopyWindows(query) else {
            return nil
        }
        defer { skyLight.releaseCF(iterator) }

        guard skyLight.iteratorAdvance(iterator) else { return nil }

        guard let wid = skyLight.iteratorGetWindowID(iterator),
              let pid = skyLight.iteratorGetPID(iterator),
              let level = skyLight.iteratorGetLevel(iterator),
              let bounds = skyLight.iteratorGetBounds(iterator),
              let tags = skyLight.iteratorGetTags(iterator),
              let attributes = skyLight.iteratorGetAttributes(iterator),
              let parentId = skyLight.iteratorGetParentID(iterator)
        else { return nil }

        return WindowSnapshot(
            windowId: wid,
            pid: pid,
            frame: bounds,
            level: level,
            tags: tags,
            attributes: attributes,
            parentId: parentId
        )
    }
}
