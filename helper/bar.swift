// hush-bar — the minimal native top bar.
//
// It intentionally contains only workspace switching, brightness, volume,
// battery and clock. There is no networking, telemetry, media integration,
// location, bluetooth, screen capture, launcher, theme engine or shell polling.
import AppKit
import CoreAudio
import Darwin
import IOKit.ps

if CommandLine.arguments.dropFirst().elementsEqual(["--quit-frontmost"]) {
    guard let application = NSWorkspace.shared.frontmostApplication,
          application.processIdentifier != getpid(), application.terminate() else {
        exit(EXIT_FAILURE)
    }
    exit(EXIT_SUCCESS)
}

// DisplayServices is the private API used by Control Center for the built-in
// panel. Resolve it at runtime so a missing private framework cannot crash-loop
// the bar; failure simply hides the brightness item.
typealias DSGetBrightnessProc = @convention(c)
    (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DSSetBrightnessProc = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias DSBrightnessProc = @convention(c)
    (UnsafeRawPointer?, CGDirectDisplayID, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
typealias DSRegisterBrightnessProc = @convention(c)
    (CGDirectDisplayID, UnsafeMutableRawPointer?, DSBrightnessProc) -> Int32

let displayServices = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    RTLD_LAZY | RTLD_LOCAL)
let dsGetBrightness: DSGetBrightnessProc? = displayServices.flatMap { handle in
    dlsym(handle, "DisplayServicesGetBrightness").map {
        unsafeBitCast($0, to: DSGetBrightnessProc.self)
    }
}
let dsSetBrightness: DSSetBrightnessProc? = displayServices.flatMap { handle in
    dlsym(handle, "DisplayServicesSetBrightness").map {
        unsafeBitCast($0, to: DSSetBrightnessProc.self)
    }
}
let dsRegisterBrightness: DSRegisterBrightnessProc? = displayServices.flatMap { handle in
    dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications").map {
        unsafeBitCast($0, to: DSRegisterBrightnessProc.self)
    }
}

let barHeight: CGFloat = 32
let workspaceFile = "/tmp/hush-bar-ws-\(getuid())"
let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"

struct Palette {
    let background: NSColor
    let foreground: NSColor
    let selection: NSColor
    let selectionText: NSColor
    let icon: NSColor
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func palette(for appearance: NSAppearance) -> Palette {
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return dark
        ? Palette(background: color(0x0f0f11), foreground: color(0xe3e4e6),
                  selection: color(0x2a2a2b), selectionText: color(0xe3e4e6),
                  icon: color(0xe3e4e6, alpha: 0.72))
        : Palette(background: color(0xeff1f5), foreground: color(0x4c4f69),
                  selection: color(0x8839ef), selectionText: color(0xeff1f5),
                  icon: color(0x8839ef))
}

@discardableResult
func aerospace(_ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: aerospaceBin)
    process.arguments = args
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

struct State {
    var workspace = ""
    var brightness: Int?
    var volume: Int?
    var muted = false
    var battery: Int?
    var charging = false
    var clock = ""
}

var state = State()
var surfaces: [BarSurface] = []

func repaint() {
    for surface in surfaces {
        surface.view.needsDisplay = true
        surface.view.displayIfNeeded()
    }
}

func setState(_ change: (inout State) -> Void) {
    change(&state)
    repaint()
}

func builtinDisplayID() -> CGDirectDisplayID {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    return displays.first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
}

func readBrightness() -> Int? {
    var value: Float = 0
    guard let get = dsGetBrightness,
          get(builtinDisplayID(), &value) == 0, value.isFinite else { return nil }
    return Int((value * 100).rounded())
}

func writeBrightness(_ percent: Int) {
    guard let set = dsSetBrightness else { return }
    let bounded = min(100, max(0, percent))
    _ = set(builtinDisplayID(), Float(bounded) / 100)
    setState { $0.brightness = bounded }
}

func defaultOutputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
}

func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: element
    )
}

func readVolume() -> (percent: Int, muted: Bool)? {
    let device = defaultOutputDevice()
    guard device != 0 else { return nil }

    var muted: UInt32 = 0
    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted)

    var level: Float32 = 0
    var address = volumeAddress(kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Float32>.size)
    if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) != noErr {
        var total: Float32 = 0
        var channels = 0
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = volumeAddress(channel)
            var channelSize = UInt32(MemoryLayout<Float32>.size)
            var value: Float32 = 0
            if AudioObjectGetPropertyData(
                device, &channelAddress, 0, nil, &channelSize, &value) == noErr {
                total += value
                channels += 1
            }
        }
        guard channels > 0 else { return nil }
        level = total / Float32(channels)
    }
    return (Int((level * 100).rounded()), muted != 0)
}

func writeVolume(_ percent: Int) {
    let device = defaultOutputDevice()
    guard device != 0 else { return }
    let bounded = min(100, max(0, percent))
    var value = Float32(bounded) / 100
    let size = UInt32(MemoryLayout<Float32>.size)
    var address = volumeAddress(kAudioObjectPropertyElementMain)
    if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) != noErr {
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = volumeAddress(channel)
            AudioObjectSetPropertyData(device, &channelAddress, 0, nil, size, &value)
        }
    }
    setState { $0.volume = bounded; $0.muted = false }
}

func writeMute(_ muted: Bool) {
    let device = defaultOutputDevice()
    guard device != 0 else { return }
    var value: UInt32 = muted ? 1 : 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectSetPropertyData(
        device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    setState { $0.muted = muted }
}

func updateVolume() {
    let value = readVolume()
    setState {
        $0.volume = value?.percent
        $0.muted = value?.muted ?? false
    }
}

func updateBattery() {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return }
    for source in sources {
        guard let data = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
            as? [String: Any],
              let current = data[kIOPSCurrentCapacityKey] as? Int else { continue }
        let maximum = data[kIOPSMaxCapacityKey] as? Int ?? 100
        let percentage = maximum > 0
            ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        let charging = (data[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        setState { $0.battery = percentage; $0.charging = charging }
        return
    }
}

func updateClock() {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d MMM  HH:mm"
    setState { $0.clock = formatter.string(from: Date()) }
}

func textSize(_ value: String, font: NSFont) -> NSSize {
    (value as NSString).size(withAttributes: [.font: font])
}

func drawText(_ value: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let size = textSize(value, font: font)
    let target = NSRect(
        x: rect.midX - size.width / 2,
        y: rect.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
    (value as NSString).draw(in: target, withAttributes: [.font: font, .foregroundColor: color])
}

func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
    let base = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    let tint = NSImage.SymbolConfiguration(paletteColors: [color])
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(base.applying(tint)), image.size.width > 0,
        image.size.height > 0 else { return }
    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                        width: size.width, height: size.height)
    image.draw(in: target)
}

final class BarView: NSView {
    var workspaceRects: [(String, NSRect)] = []
    var itemRects: [String: NSRect] = [:]
    let workspaces = (1...9).map(String.init)
    let regular = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let bold = NSFont.systemFont(ofSize: 12, weight: .bold)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = palette(for: effectiveAppearance)
        colors.background.setFill()
        NSBezierPath(rect: bounds).fill()
        workspaceRects.removeAll(keepingCapacity: true)
        itemRects.removeAll(keepingCapacity: true)

        var x: CGFloat = 12
        for workspace in workspaces {
            let rect = NSRect(x: x, y: 5, width: 24, height: 22)
            let focused = workspace == state.workspace
            if focused {
                colors.selection.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            drawText(workspace, in: rect, font: focused ? bold : regular,
                     color: focused ? colors.selectionText
                                    : colors.foreground.withAlphaComponent(0.84))
            workspaceRects.append((workspace, rect))
            x += 30
        }

        var items: [(key: String, symbol: String, label: String)] = []
        if let brightness = state.brightness {
            items.append(("brightness", "sun.max.fill", "\(brightness)%"))
        }
        if let volume = state.volume {
            let symbol = state.muted ? "speaker.slash.fill"
                : volume < 35 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
            items.append(("volume", symbol, state.muted ? "Muted" : "\(volume)%"))
        }
        if let battery = state.battery {
            items.append(("battery", state.charging ? "bolt.fill" : "battery.100percent",
                          "\(battery)%"))
        }
        items.append(("clock", "calendar", state.clock))

        // macOS places its camera/microphone privacy dot at the far-right edge.
        var right = bounds.maxX - 26
        for item in items.reversed() {
            let labelWidth = ceil(textSize(item.label, font: regular).width)
            let width = labelWidth + 26
            let rect = NSRect(x: right - width, y: 3, width: width, height: 26)
            drawSymbol(item.symbol,
                       in: NSRect(x: rect.minX, y: rect.midY - 7, width: 18, height: 14),
                       color: colors.icon)
            let labelRect = NSRect(x: rect.minX + 22, y: rect.minY,
                                   width: labelWidth, height: rect.height)
            drawText(item.label, in: labelRect, font: regular, color: colors.foreground)
            itemRects[item.key] = rect
            right = rect.minX - 16
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let workspace = workspaceRects.first(where: { $0.1.contains(point) })?.0 {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = aerospace(["workspace", workspace])
            }
            return
        }
        if itemRects["volume"]?.contains(point) == true {
            writeMute(!state.muted)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.scrollingDeltaY != 0 else { return }
        let step = event.scrollingDeltaY > 0 ? 5 : -5
        if itemRects["volume"]?.contains(point) == true, let value = state.volume {
            writeVolume(value + step)
        } else if itemRects["brightness"]?.contains(point) == true,
                  let value = state.brightness {
            writeBrightness(value + step)
        }
    }
}

final class BarWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BarSurface {
    var screen: NSScreen
    let window: BarWindow
    let view: BarView

    init(screen: NSScreen) {
        self.screen = screen
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - barHeight,
            width: screen.frame.width,
            height: barHeight
        )
        window = BarWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: -20)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        view = BarView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderFrontRegardless()
    }

    func place(on screen: NSScreen) {
        self.screen = screen
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - barHeight,
            width: screen.frame.width,
            height: barHeight
        )
        window.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
    }
}

func displayID(_ screen: NSScreen) -> UInt32 {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

func rebuildSurfaces() {
    var kept: [BarSurface] = []
    for screen in NSScreen.screens {
        if let existing = surfaces.first(where: { displayID($0.screen) == displayID(screen) }) {
            existing.place(on: screen)
            kept.append(existing)
        } else {
            kept.append(BarSurface(screen: screen))
        }
    }
    for old in surfaces where !kept.contains(where: { $0 === old }) {
        old.window.orderOut(nil)
    }
    surfaces = kept
    repaint()
}

var workspaceWatch: (any DispatchSourceFileSystemObject)?

func watchWorkspaceFile() {
    if !FileManager.default.fileExists(atPath: workspaceFile) {
        FileManager.default.createFile(atPath: workspaceFile, contents: nil)
        chmod(workspaceFile, 0o600)
    }
    let descriptor = open(workspaceFile, O_EVTONLY)
    guard descriptor >= 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: watchWorkspaceFile)
        return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .delete, .rename],
        queue: .main
    )
    source.setEventHandler {
        if let value = try? String(contentsOfFile: workspaceFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            setState { $0.workspace = value }
        }
        if source.data.contains(.delete) || source.data.contains(.rename) { source.cancel() }
    }
    source.setCancelHandler {
        close(descriptor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: watchWorkspaceFile)
    }
    workspaceWatch = source
    source.resume()
}

var volumeListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

func attachVolumeListeners() {
    for (object, address, block) in volumeListeners {
        var mutableAddress = address
        AudioObjectRemovePropertyListenerBlock(object, &mutableAddress, .main, block)
    }
    volumeListeners.removeAll()

    let device = defaultOutputDevice()
    guard device != 0 else { return }
    let block: AudioObjectPropertyListenerBlock = { _, _ in updateVolume() }
    for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
            volumeListeners.append((device, address, block))
        }
    }
    updateVolume()
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
umask(0o077)

state.workspace = aerospace(["list-workspaces", "--focused"])
    .trimmingCharacters(in: .whitespacesAndNewlines)
state.brightness = readBrightness()
rebuildSurfaces()
watchWorkspaceFile()
updateVolume()
updateBattery()
updateClock()

let powerCallback: IOPowerSourceCallbackType = { _ in
    DispatchQueue.main.async { updateBattery() }
}
if let source = IOPSNotificationCreateRunLoopSource(powerCallback, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
}

var defaultDeviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main) { _, _ in
        attachVolumeListeners()
    }
attachVolumeListeners()

let brightnessCallback: DSBrightnessProc = { _, _, _, _ in
    DispatchQueue.main.async { setState { $0.brightness = readBrightness() } }
}
// The listener follows the built-in display present at launch. Screen-layout
// changes still rebuild the bar surfaces independently.
_ = dsRegisterBrightness?(builtinDisplayID(), nil, brightnessCallback)

func scheduleClock() {
    updateClock()
    let now = Date()
    let next = Calendar.current.nextDate(
        after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
        ?? now.addingTimeInterval(60)
    DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow)) {
        scheduleClock()
    }
}
scheduleClock()

NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil,
    queue: .main
) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rebuildSurfaces() }
}

app.run()
