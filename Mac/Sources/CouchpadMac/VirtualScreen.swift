import CGVirtualDisplay
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// A screen of our own for a MacBook with its lid closed.
///
/// Closed, with no monitor attached, macOS keeps the built-in display dark ("Clamshell Sleep"
/// in `pmset -g log`). Every touch from the phone wakes it, ten seconds later it goes dark
/// again, and the picture's stream dies with it each time. No power assertion changes that.
/// A virtual display does: with one attached the closed Mac is in closed-display mode, as
/// with an external monitor, and nothing goes dark. Where it ends up depends on the moment:
/// - Just closed, the built-in display is still on (Couchpad wakes the displays first, see
///   `wakeDisplays`). The virtual one then mirrors it, out of the way: the phone keeps seeing
///   the real desktop at its own size, no window moves, and the cursor can't wander off
///   onto an empty screen.
/// - Closed for a while, the built-in display is gone (macOS shows a 1920×1080 stand-in).
///   The virtual one becomes the only screen, at 16:10, and the windows move onto it.
///
/// Only on the charger, though. On battery macOS sleeps a closed Mac whatever is attached or
/// asserted (the power log says 'Clamshell Sleep' a few seconds after the lid closes, with
/// PreventSystemSleep held); only root can change that (`pmset disablesleep`), and then the
/// Mac would never sleep in a bag either. So on battery there is no screen, and the phone
/// is told to plug the Mac in.
///
/// Used from the streamer's queue only.
final class VirtualScreen {
    /// 16:10 in points, drawn at 2× (2880×1800 pixels): roomy like a 13-inch MacBook, with
    /// text big enough to read on a phone, and the shape of a sideways phone's picture pane.
    static let width = 1440, height = 900
    /// Ours, so it is never mistaken for a monitor: "CPAD" in the vendor and product IDs.
    private static let vendorID: UInt32 = 0x4350, productID: UInt32 = 0x4144
    /// How long the screen stays after the last phone stopped wanting the picture. Taking it
    /// away moves every window to macOS's stand-in display and back again on the next look.
    static let linger: CFTimeInterval = 5 * 60

    private var display: CGVirtualDisplay?
    private var assertions: [IOPMAssertionID] = []
    var displayID: CGDirectDisplayID? { display?.displayID }

    /// The lid, as power management sees it.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (state as? Bool) ?? false
    }

    /// Running on the charger (closed-display mode needs it).
    static var onACPower: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// A real screen besides the built-in one (a monitor, a TV, Sidecar): the closed Mac uses
    /// that and needs nothing from us. macOS's own stand-in for "no screen at all" and our
    /// virtual display don't count.
    static func monitorAttached() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { id in
            CGDisplayIsBuiltin(id) == 0 && !isOurs(id) && !isStandIn(id)
        }
    }

    /// Every online display, for the log when the lid closes onto what looks like a monitor.
    static func describeDisplays() -> String {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return "?" }
        return ids.prefix(Int(count)).map { id in
            String(format: "%u %dx%d builtin %d vendor 0x%x model 0x%x serial 0x%x", id, Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id)),
                   CGDisplayIsBuiltin(id), CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id))
        }.joined(separator: "; ")
    }

    private static func isOurs(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == productID
    }

    /// The 1920×1080 display WindowServer conjures when no screen is on (lid closed, nothing
    /// attached). It has no EDID behind it.
    private static func isStandIn(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0 && CGDisplayModelNumber(id) == 0 && CGDisplaySerialNumber(id) == 0
    }

    /// Attaches the screen. False if macOS refused.
    func add() -> Bool {
        guard display == nil else { return true }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "Couchpad"
        descriptor.maxPixelsWide = UInt32(Self.width * 2)
        descriptor.maxPixelsHigh = UInt32(Self.height * 2)
        // A 13-inch panel, so macOS picks sensible default scaling.
        descriptor.sizeInMillimeters = CGSize(width: 286, height: 179)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = 1
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return false }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt(Self.width * 2), height: UInt(Self.height * 2), refreshRate: 60),
                          CGVirtualDisplayMode(width: UInt(Self.width), height: UInt(Self.height), refreshRate: 60)]
        guard display.apply(settings) else { return false }
        self.display = display
        // The Mac must not sleep under the phone, nor its screen idle off: nobody else sees it.
        for type in [kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Showing the closed Mac's screen on the phone" as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        Self.wakeDisplays()
        return true
    }

    /// Settles where the screen goes, a moment after `add` (once WindowServer has set it up):
    /// mirroring the built-in display if that is on, otherwise the only screen, in HiDPI.
    func arrange() -> String {
        guard let id = displayID else { return "gone" }
        if let builtin = Self.activeBuiltIn() {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                CGConfigureDisplayMirrorOfDisplay(config, id, builtin)
                if CGCompleteDisplayConfiguration(config, .forSession) == .success { return "mirroring the built-in display" }
            }
            NSLog("Screen: could not mirror the virtual display onto the built-in one")
        }
        useHiDPIMode()
        return "the only screen"
    }

    /// The virtual display is the main screen on its own (the built-in one dropped out
    /// under it) but still in the 1× mode it came up in: switch it, true if it did.
    func fixModeIfAlone() -> Bool {
        guard let id = displayID, CGMainDisplayID() == id, CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
              let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth != Self.width * 2 || mode.width != Self.width else { return false }
        useHiDPIMode()
        return true
    }

    private static func activeBuiltIn() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    /// Turns the displays on, as a touch would. A closed lid puts them all to sleep; a
    /// virtual display that comes up while they sleep stays blank to ScreenCaptureKit.
    static func wakeDisplays() {
        IOPMAssertionDeclareUserActivity("Couchpad screen" as CFString, kIOPMUserActiveLocal, &activityID)
    }
    private static var activityID: IOPMAssertionID = 0

    func remove() {
        display = nil   // releasing it detaches the screen
        for id in assertions { IOPMAssertionRelease(id) }
        assertions = []
    }

    /// The display comes up in some 1× mode; pick 1440×900 points backed by 2880×1800 pixels.
    private func useHiDPIMode() {
        guard let id = displayID else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let mode = modes.first(where: { $0.width == Self.width && $0.pixelWidth == Self.width * 2 }) else {
            NSLog("Screen: no HiDPI mode on the virtual display; keeping its default")
            return
        }
        let result = CGDisplaySetDisplayMode(id, mode, nil)
        if result != .success { NSLog("Screen: could not switch the virtual display to HiDPI (%d)", result.rawValue) }
    }
}
