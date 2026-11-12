import CGVirtualDisplay
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// A screen of our own for a Mac with no screen on: a MacBook with its lid closed and no
/// monitor, or a desktop Mac with no monitor.
///
/// Closed, with no monitor attached, macOS keeps the built-in display dark ("Clamshell Sleep"
/// in `pmset -g log`). Every touch from the phone wakes it, ten seconds later it goes dark
/// again, and the picture's stream dies with it each time. No power assertion changes that.
/// A virtual display does: with one attached the closed Mac is in closed-display mode, as
/// with an external monitor, and nothing goes dark.
///
/// What it looks like depends on the phone. A phone that says what desktop it would like
/// (`v d`, see `pointSize(forDesk:)`) gets the virtual display in its picture's shape, and
/// the desktop is laid out on it: if the built-in display is still on, the built-in one
/// mirrors the virtual one, not the other way round. A phone that says nothing gets the
/// legacy arrangement, which depends on the moment:
/// - Just closed, the built-in display is still on (Couchpad wakes the displays first, see
///   `wakeDisplays`). The virtual one then mirrors it, out of the way: the phone keeps seeing
///   the real desktop at its own size, no window moves, and the cursor can't wander off
///   onto an empty screen.
/// - Closed for a while, the built-in display is gone (macOS shows a 1920×1080 stand-in).
///   The virtual one becomes the only screen, at 16:10, and the windows move onto it.
///
/// Only on the charger, though, for a MacBook. On battery macOS sleeps a closed Mac whatever
/// is attached or asserted (the power log says 'Clamshell Sleep' a few seconds after the lid
/// closes, with PreventSystemSleep held); only root can change that (`pmset disablesleep`),
/// and then the Mac would never sleep in a bag either. So on battery there is no screen, and
/// the phone is told to plug the Mac in.
///
/// Used from the streamer's queue only.
final class VirtualScreen {
    /// A display size in points; it is drawn at 2× (HiDPI).
    struct Size: Equatable, CustomStringConvertible {
        var width: Int
        var height: Int
        var description: String { "\(width)×\(height)" }
    }

    /// What the screen was made into: its size, and whether the desktop is laid out on it
    /// for the phone (`shaped`) or it takes the legacy arrangement (see the type's comment).
    struct Shape: Equatable, CustomStringConvertible {
        var size: Size
        var shaped: Bool
        var description: String { "\(size) \(shaped ? "shaped for the phone" : "legacy")" }
        static let legacy = Shape(size: VirtualScreen.legacySize, shaped: false)
    }

    /// 16:10 in points, drawn at 2× (2880×1800 pixels): roomy like a 13-inch MacBook, with
    /// text big enough to read on a phone, and the shape of a sideways phone's picture pane.
    /// For phones that don't ask for a shape of their own.
    static let legacySize = Size(width: 1440, height: 900)
    /// Bounds on a shape asked for by a phone. Below 800 points wide macOS's own windows
    /// (System Settings, open and save panels) no longer fit. The height floor is 600: on the
    /// user's MacBook macOS offered an 800×520 HiDPI mode and then refused to switch to it
    /// (error 1001), while 800×638 and up worked; 800×600 is macOS's classic minimum, not a
    /// verified threshold. Past 1920 points a side the 2× pixels would pass `maxPixels`, and
    /// text would be too small to read on a phone anyway. A request outside is scaled as a
    /// whole, so the shape stays the pane's.
    static let minWidth = 800, minHeight = 600, maxSide = 1920
    /// The largest pixel size the display can take, either way round: 2× the largest side,
    /// so any shape fits without making the display again.
    private static let maxPixels: UInt32 = 3840
    /// Ours, so it is never mistaken for a monitor: "CPAD" in the vendor and product IDs.
    private static let vendorID: UInt32 = 0x4350, productID: UInt32 = 0x4144
    /// How long the screen stays after the last phone stopped wanting the picture. Taking it
    /// away moves every window to macOS's stand-in display and back again on the next look.
    static let linger: CFTimeInterval = 5 * 60

    private var display: CGVirtualDisplay?
    private var assertions: [IOPMAssertionID] = []
    /// The serial number of the display, switched between 1 and 2 when it is made again
    /// (`replace`), so the new one is a display of its own while the old one is still there.
    private var serial: UInt32 = 1
    var displayID: CGDirectDisplayID? { display?.displayID }
    /// The size its modes were last given.
    private(set) var size = VirtualScreen.legacySize { didSet { modeFixes = 0 } }
    /// How often `fixModeIfAlone` switched the mode at this size. Twice is the limit: a
    /// switch that reports success but does not stick (a mirror set holding the mode, say)
    /// would otherwise restart the stream every half second and the phone would get nothing.
    private var modeFixes = 0
    /// Moves whenever the screen is added or removed, so steps scheduled for one screen
    /// never act on the next.
    private(set) var generation = 0

    /// Turns the desktop a phone asked for (`v d`, in points) into the display's size: scaled
    /// up as a whole until it is at least `minWidth`×`minHeight`, down as a whole if a side
    /// would pass `maxSide`, each side rounded to an even number. Pure, so it is easy to check.
    static func pointSize(forDesk desk: Size) -> Size {
        let w = Double(max(1, desk.width)), h = Double(max(1, desk.height))
        var scale = max(1, Double(minWidth) / w, Double(minHeight) / h)
        scale = min(scale, Double(maxSide) / max(w, h))
        func even(_ x: Double) -> Int { max(2, Int((x / 2).rounded()) * 2) }
        return Size(width: min(maxSide, even(w * scale)), height: min(maxSide, even(h * scale)))
    }

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

    /// A real screen is on: a monitor, a TV, Sidecar, or the built-in display while the lid is
    /// open (asleep or not: it is still the Mac's own screen). Then the Mac needs nothing from
    /// us. macOS's own stand-in for "no screen at all", our virtual display, and the built-in
    /// display behind a closed lid don't count.
    static func realScreenOn(lidClosed: Bool) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).contains { id in
            !isOurs(id) && !isStandIn(id) && !(lidClosed && CGDisplayIsBuiltin(id) != 0)
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

    /// Modes for `size`: 2× and 1×, so macOS offers the 2× one as a HiDPI mode of `size` points.
    private static func settings(for size: Size) -> CGVirtualDisplaySettings {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt(size.width * 2), height: UInt(size.height * 2), refreshRate: 60),
                          CGVirtualDisplayMode(width: UInt(size.width), height: UInt(size.height), refreshRate: 60)]
        return settings
    }

    /// A new display of `size`, not yet kept anywhere. Nil if macOS refused.
    private func makeDisplay(size: Size, serial: UInt32) -> CGVirtualDisplay? {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "Couchpad"
        descriptor.maxPixelsWide = Self.maxPixels
        descriptor.maxPixelsHigh = Self.maxPixels
        // A 13-inch panel's density (286 mm across 1440 points), so macOS picks sensible
        // default scaling whatever the shape.
        descriptor.sizeInMillimeters = CGSize(width: (Double(size.width) * 286 / 1440).rounded(),
                                              height: (Double(size.height) * 286 / 1440).rounded())
        descriptor.vendorID = Self.vendorID
        descriptor.productID = Self.productID
        descriptor.serialNum = serial
        guard let display = CGVirtualDisplay(descriptor: descriptor), display.apply(Self.settings(for: size)) else { return nil }
        return display
    }

    /// Attaches the screen at `size`. False if macOS refused.
    func add(size: Size) -> Bool {
        guard display == nil else { return true }
        guard let display = makeDisplay(size: size, serial: serial) else { return false }
        self.display = display
        self.size = size
        generation += 1
        // The Mac must not sleep under the phone, nor its screen idle off: nobody else sees it.
        for type in [kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Showing the Mac's screen on the phone" as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        Self.wakeDisplays()
        return true
    }

    /// Gives the display the modes for `size`, in place. True if it took the settings;
    /// whether macOS really offers the new mode shows a moment later (`offersMode`).
    func resize(to size: Size) -> Bool {
        guard let display else { return false }
        guard display.apply(Self.settings(for: size)) else { return false }
        self.size = size
        return true
    }

    /// Makes the display again at `size`, for when resizing in place did not take. The new
    /// one comes up before the old one goes (under a serial of its own), so the closed Mac
    /// is never without a screen in between and drops into clamshell sleep. False if macOS
    /// refused; the old display then stays as it is.
    func replace(size: Size) -> Bool {
        guard display != nil else { return false }
        let serial: UInt32 = self.serial == 1 ? 2 : 1
        guard let fresh = makeDisplay(size: size, serial: serial) else { return false }
        display = fresh   // releasing the old one detaches it
        self.serial = serial
        self.size = size
        Self.wakeDisplays()
        return true
    }

    /// Whether the display offers `size` in HiDPI (2× pixels).
    func offersMode(_ size: Size) -> Bool { !hiDPIModes(size).isEmpty }

    /// Settles where the screen goes, a moment after `add` or a reshape (once WindowServer has
    /// set it up), and says what came of it for the log.
    /// - Legacy (`shaped` false): mirroring the built-in display if that is on, otherwise the
    ///   only screen, in HiDPI.
    /// - Shaped: the desktop is laid out on the virtual display. A built-in display still on
    ///   mirrors it (the virtual one is the master, as System Settings does when a mirror is
    ///   "optimised for" an external display), and it takes its HiDPI mode. If macOS refuses
    ///   that, the legacy arrangement, so the phone still gets a picture.
    func arrange(shaped: Bool) -> String {
        guard let id = displayID else { return "gone" }
        if shaped {
            var result: String
            // The built-in display we mirror (legacy) counts even when it reads as asleep: we
            // must stop mirroring it either way, or it stays the main display.
            let mirrored = CGDisplayMirrorsDisplay(id)
            let mirroredBuiltIn = mirrored != kCGNullDirectDisplay && CGDisplayIsBuiltin(mirrored) != 0 ? mirrored : nil
            if let builtin = Self.activeBuiltIn() ?? mirroringBuiltIn() ?? mirroredBuiltIn {
                var config: CGDisplayConfigRef?
                if CGBeginDisplayConfiguration(&config) == .success, let config {
                    CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
                    CGConfigureDisplayMirrorOfDisplay(config, builtin, id)
                    if CGCompleteDisplayConfiguration(config, .forSession) == .success {
                        result = "\(size) for the phone, the built-in display mirroring it"
                    } else {
                        CGCancelDisplayConfiguration(config)
                        NSLog("Screen: could not make the built-in display mirror the virtual one; mirroring the built-in display instead")
                        return arrangeLegacy(id) + " (shaping failed)"
                    }
                } else {
                    NSLog("Screen: could not configure the displays; mirroring the built-in display instead")
                    return arrangeLegacy(id) + " (shaping failed)"
                }
            } else {
                result = "\(size) for the phone, the only screen"
            }
            if !useHiDPIMode() { result += ", not in HiDPI" }
            return result + (CGMainDisplayID() == id ? ", the main display" : ", not (yet) the main display")
        }
        return arrangeLegacy(id)
    }

    /// The legacy arrangement (see `arrange`). A built-in display left mirroring ours by an
    /// earlier shaped arrangement is let go first, or the two would mirror each other.
    private func arrangeLegacy(_ id: CGDirectDisplayID) -> String {
        if let builtin = Self.activeBuiltIn() ?? mirroringBuiltIn() {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                if CGDisplayMirrorsDisplay(builtin) == id { CGConfigureDisplayMirrorOfDisplay(config, builtin, kCGNullDirectDisplay) }
                CGConfigureDisplayMirrorOfDisplay(config, id, builtin)
                if CGCompleteDisplayConfiguration(config, .forSession) == .success { return "mirroring the built-in display" }
            }
            NSLog("Screen: could not mirror the virtual display onto the built-in one")
        }
        useHiDPIMode()
        return "the only screen"
    }

    /// The virtual display is the main screen on its own (the built-in one dropped out
    /// under a legacy mirror) but not in its HiDPI mode: switch it, true if it did. A mode
    /// that isn't offered is left alone, or every stream start would come back here.
    func fixModeIfAlone() -> Bool {
        guard let id = displayID, CGMainDisplayID() == id, CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
              let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth != size.width * 2 || mode.width != size.width || mode.height != size.height,
              offersMode(size), modeFixes < 2 else { return false }
        modeFixes += 1
        return useHiDPIMode()
    }

    private static func activeBuiltIn() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    /// The built-in display mirroring ours (a shaped arrangement): a mirror need not show
    /// up among the active displays.
    private func mirroringBuiltIn() -> CGDirectDisplayID? {
        guard let id = displayID else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayMirrorsDisplay($0) == id }
    }

    /// Turns the displays on, as a touch would. A closed lid puts them all to sleep; a
    /// virtual display that comes up while they sleep stays blank to ScreenCaptureKit.
    static func wakeDisplays() {
        IOPMAssertionDeclareUserActivity("Couchpad screen" as CFString, kIOPMUserActiveLocal, &activityID)
    }
    private static var activityID: IOPMAssertionID = 0

    func remove() {
        display = nil   // releasing it detaches the screen
        generation += 1
        for id in assertions { IOPMAssertionRelease(id) }
        assertions = []
    }

    /// Every mode of `size` points backed by twice the pixels, the ones macOS calls usable
    /// for a desktop first. The list with duplicates shown can hold more than one such mode,
    /// and not every one is a mode macOS will switch to.
    private func hiDPIModes(_ size: Size) -> [CGDisplayMode] {
        guard let id = displayID else { return [] }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [])
            .filter { $0.width == size.width && $0.height == size.height && $0.pixelWidth == size.width * 2 }
        return modes.filter { $0.isUsableForDesktopGUI() } + modes.filter { !$0.isUsableForDesktopGUI() }
    }

    /// Whether WindowServer has caught up with an arrangement, so a stream started now gets
    /// the new screen: the display shows its size in points (in HiDPI or, if that was
    /// refused, at 1×; the mode and the bounds the stream and the absolute pointer read) and,
    /// shaped, it is the main display. A legacy mirror of the built-in display has nothing
    /// to wait for: the capture stays on the built-in one. Gone, nothing either.
    func isSettled(shaped: Bool) -> Bool {
        guard let id = displayID else { return true }
        if !shaped, CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { return true }
        guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
        let bounds = CGDisplayBounds(id).size
        return mode.width == size.width && mode.height == size.height
            && Int(bounds.width) == size.width && Int(bounds.height) == size.height
            && (!shaped || CGMainDisplayID() == id)
    }

    /// The display comes up in some 1× mode; pick `size` points backed by twice the pixels.
    /// Each matching mode is tried until macOS takes one; only if none is taken is it logged.
    @discardableResult
    private func useHiDPIMode() -> Bool {
        guard let id = displayID else { return false }
        let modes = hiDPIModes(size)
        guard !modes.isEmpty else {
            NSLog("Screen: no %@ HiDPI mode on the virtual display; keeping its default", size.description)
            return false
        }
        var result = CGError.success
        for mode in modes {
            result = CGDisplaySetDisplayMode(id, mode, nil)
            if result == .success { return true }
        }
        NSLog("Screen: could not switch the virtual display to %@ HiDPI (%d modes tried, last error %d)", size.description, modes.count, result.rawValue)
        return false
    }
}
