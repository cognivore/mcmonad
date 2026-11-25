import Foundation

/// How many times a window that has just appeared is read, at most, before
/// the brain is told what it said.
let maxWindowReads = 4

/// The pause between two readings of a window that has just appeared.
let windowRereadNanoseconds: UInt64 = 100_000_000

/// Whether to read a window that has just appeared again, after `reads`
/// readings, before telling the brain about it.
///
/// A window is reported once, and what it says of itself then decides for
/// good whether it is tiled or left floating where its application put it.
/// An application still putting a window up can say less than is true. A
/// full Chrome window read while it was sliding into place had no usable
/// fullscreen or zoom button, and was floated at a size it was passing
/// through.
///
/// Only an ordinary window that says it cannot be made full screen or
/// resized is doubted: a dialog is what it says it is. One that really
/// cannot is reported a moment later than it would have been, and it is
/// left where its application put it either way.
func shouldReadAgain(_ info: WindowInfo, reads: Int) -> Bool {
    info.subrole == "AXStandardWindow"
        && (info.isFixedSize || !info.hasFullscreenButton)
        && reads < maxWindowReads
}
