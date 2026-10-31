import Foundation
import CoreAudio

final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var items: [AudioDevice] = []
    var blocked = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var callback: (@Sendable () -> Void)?
    var stopped = false
    private var published: [AudioDevice] = []
    var observed: [AudioDevice] { lock.lock(); defer { lock.unlock() }; return published }
    func load() -> [AudioDevice] {
        lock.lock(); calls += 1; let wait = blocked; let captured = items; lock.unlock()
        if wait { entered.signal(); release.wait() }
        return captured
    }
    func change(_ items: [AudioDevice], blocked: Bool = false) { lock.lock(); self.items = items; self.blocked = blocked; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func observe(_ changed: @escaping @Sendable () -> Void) -> AudioDeviceObservation {
        lock.lock(); callback = changed; lock.unlock()
        return AudioDeviceObservation(update: { self.lock.lock(); self.published = $0; self.lock.unlock() }, cancel: { self.lock.lock(); self.stopped = true; self.callback = nil; self.lock.unlock() })
    }
}
@main struct Checks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    static func until(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try require(condition(), "inventory did not publish")
    }
    static func main() throws {
        let fixture = Fixture()
        let mic = AudioDevice(id: 11, uid: "fixture-mic", name: "Mic", inputChannels: 1, outputChannels: 0, transport: kAudioDeviceTransportTypeUSB)
        fixture.change([mic])
        let inventory = AudioDeviceInventory(load: { fixture.load() }, observe: { _, changed in fixture.observe(changed) })
        try until { inventory.snapshot == [mic] }
        try require(fixture.count == 1, "initial enumeration repeated")
        for _ in 0..<10_000 { _ = inventory.snapshot }
        try require(fixture.count == 1, "snapshot enumerated")
        print("PASS: one initial enumeration and no HAL calls for repeated readers")
        fixture.change([], blocked: true)
        fixture.callback?()
        try require(fixture.entered.wait(timeout: .now() + 2) == .success, "refresh did not start")
        let started = Date()
        for _ in 0..<10_000 { _ = inventory.snapshot }
        try require(Date().timeIntervalSince(started) < 0.5, "slow enumeration blocked readers")
        fixture.release.signal()
        try until { inventory.snapshot.isEmpty }
        print("PASS: slow refresh never blocks readers; loss replaces cached identity")
        fixture.change([mic])
        for _ in 0..<100 { fixture.callback?() }
        try until { inventory.snapshot == [mic] }
        try require(fixture.count == 3, "change burst did not coalesce")
        print("PASS: coalesced change burst publishes restored devices")
        let first = Fixture(), second = Fixture()
        first.change([mic])
        let isolatedA = AudioDeviceInventory(load: { first.load() }, observe: { _, changed in first.observe(changed) })
        let isolatedB = AudioDeviceInventory(load: { second.load() }, observe: { _, changed in second.observe(changed) })
        defer { isolatedA.stop(); isolatedB.stop() }
        try until { first.observed == [mic] && second.count == 1 }
        try require(second.observed.isEmpty, "second inventory received another owner's devices")
        second.change([mic]); second.callback?()
        try until { second.observed == [mic] }
        first.change([]); first.callback?()
        try until { first.observed.isEmpty }
        try require(second.observed == [mic], "unrelated publication replaced listener device registrations")
        print("PASS: observation updates are owner-bound across independent inventories")
        let concurrent = Fixture()
        concurrent.change([mic], blocked: true)
        let refreshing = AudioDeviceInventory(load: { concurrent.load() }, observe: { _, changed in concurrent.observe(changed) })
        defer { refreshing.stop() }
        try require(concurrent.entered.wait(timeout: .now() + 2) == .success, "loader did not block")
        concurrent.change([])
        concurrent.callback?()
        concurrent.release.signal()
        try until { concurrent.count == 2 && refreshing.snapshot.isEmpty && concurrent.observed.isEmpty }
        try require(concurrent.observed.isEmpty, "change during load was overwritten by stale result")
        print("PASS: genuine change during an in-flight load triggers a fresh reconciliation")
        inventory.stop()
        try require(inventory.snapshot.isEmpty && fixture.stopped, "stop retained cache or listener")
        inventory.refresh()
        Thread.sleep(forTimeInterval: 0.03)
        try require(fixture.count == 3, "stale refresh ran after stop")
        print("PASS: stopped inventory clears snapshot and removes listener")
        try defaultDeviceChecks()
        try driverStatusChecks()
        try driverCommandChecks()
        try driverDigestChecks()
    }
}

func device(_ id: AudioDeviceID, _ uid: String, _ name: String, inputs: Int = 2, outputs: Int = 2,
            transport: UInt32 = kAudioDeviceTransportTypeVirtual) -> AudioDevice {
    AudioDevice(id: id, uid: uid, name: name, inputChannels: inputs, outputChannels: outputs, transport: transport)
}

func defaultDeviceChecks() throws {
    let microphone = device(21, AudioDevice.babelfinMicrophoneUID, "Babelfin Microphone")
    let speaker = device(22, AudioDevice.babelfinSpeakerUID, "Babelfin Speaker")
    let blackHole = device(23, "BlackHole2ch_UID", "BlackHole 2ch")
    let usb = device(24, "usb-mic", "USB microphone", inputs: 1, outputs: 0, transport: kAudioDeviceTransportTypeUSB)
    try Checks.require(DefaultAudioDevice.outgoingOutput(from: [blackHole, speaker, microphone]) == AudioDevice.babelfinMicrophoneUID, "outgoing did not prefer Babelfin Microphone")
    try Checks.require(DefaultAudioDevice.outgoingOutput(from: [speaker]) == nil, "outgoing selected Babelfin Speaker")
    try Checks.require(DefaultAudioDevice.outgoingOutput(from: [speaker, blackHole]) == blackHole.uid, "outgoing missed the only other loopback")
    try Checks.require(DefaultAudioDevice.incomingSource(from: [usb, blackHole, microphone, speaker]) == AudioDevice.babelfinSpeakerUID, "incoming did not prefer Babelfin Speaker")
    try Checks.require(DefaultAudioDevice.incomingSource(from: [usb, blackHole, microphone]) == nil, "incoming selected a device other than Babelfin Speaker")
    print("PASS: default devices prefer Babelfin Microphone for Your voice and Babelfin Speaker for Meeting audio")
}

func driverStatusChecks() throws {
    let a = "a", b = "b"
    func item(_ bundled: String?, _ installed: String?, _ loaded: Bool) -> AudioDriverObservation {
        AudioDriverObservation(bundledDigest: bundled, installedDigest: installed, deviceLoaded: loaded)
    }
    let cases: [([AudioDriverObservation], AudioDriverStatus)] = [
        ([item(a, nil, false), item(b, nil, false)], .notInstalled),
        ([item(a, a, true), item(b, b, true)], .installed),
        ([item(nil, a, true), item(nil, b, true)], .installed),
        ([item(a, "old", true), item(b, b, true)], .versionDiffers),
        ([item(a, a, true), item(b, nil, false)], .incomplete),
        ([item(a, a, false), item(b, b, true)], .notLoaded),
        ([item(a, nil, true), item(b, nil, false)], .removalPending),
        ([item(nil, nil, false), item(nil, nil, false)], .notInstalled)
    ]
    for (observations, expected) in cases {
        try Checks.require(AudioDriverStatus.evaluate(observations) == expected, "status \(expected) was not detected")
    }
    print("PASS: driver status distinguishes not installed, installed, version differs, incomplete, not loaded and removal pending")
}

func shell(_ command: String) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

func driverCommandChecks() throws {
    let hostile = "/Volumes/Test Disk/My 'App' $(echo injected) `id` \"q\" \\ ; & | * ?/Babelfin.app/Contents/Resources/AudioDrivers"
    let printed = try shell("printf %s " + AudioDriverInstaller.shellQuote(hostile))
    try Checks.require(printed == hostile, "shell quoting changed a path")
    let install = try AudioDriverInstaller.installCommand(sourceDirectory: "/Applications/Babelfin.app/Contents/Resources/AudioDrivers")
    let hal = "'/Library/Audio/Plug-Ins/HAL/Babelfin Microphone.driver' '/Library/Audio/Plug-Ins/HAL/Babelfin Speaker.driver'"
    let expected = [
        "/bin/mkdir -p '/Library/Audio/Plug-Ins/HAL'",
        "/bin/rm -rf " + hal,
        "/usr/bin/ditto --noextattr --noqtn --noacl '/Applications/Babelfin.app/Contents/Resources/AudioDrivers/Babelfin Microphone.driver' '/Library/Audio/Plug-Ins/HAL/Babelfin Microphone.driver'",
        "/usr/bin/ditto --noextattr --noqtn --noacl '/Applications/Babelfin.app/Contents/Resources/AudioDrivers/Babelfin Speaker.driver' '/Library/Audio/Plug-Ins/HAL/Babelfin Speaker.driver'",
        "/usr/sbin/chown -R root:wheel " + hal,
        "/usr/bin/killall -9 coreaudiod"
    ].joined(separator: " && ")
    try Checks.require(install == expected, "install command differs:\n\(install)")
    try Checks.require(AudioDriverInstaller.removeCommand() == "/bin/rm -rf " + hal + " && /usr/bin/killall -9 coreaudiod", "remove command differs")
    let quotedSource = try AudioDriverInstaller.installCommand(sourceDirectory: hostile + "/")
    try Checks.require(quotedSource.contains(AudioDriverInstaller.shellQuote(hostile + "/Babelfin Speaker.driver")), "hostile source path was not quoted as one word")
    for bad in ["relative/AudioDrivers", "/Apps/Line\nBreak", "/Apps/Return\rChar", "/Apps/Nul\u{0}Char"] {
        do { _ = try AudioDriverInstaller.installCommand(sourceDirectory: bad); throw NSError(domain: "unsafe source accepted", code: 1) }
        catch let error as AudioDriverInstallerError { try Checks.require(error == .unsafePath, "wrong error for unsafe source") }
    }
    for command in [install, quotedSource, AudioDriverInstaller.removeCommand()] {
        try Checks.require(!command.contains("defaults") && !command.contains("SwitchAudioSource") && !command.contains("sudo"), "command changes more than the bundles")
    }
    // Compile only. Running the script would ask for an administrator password.
    let literal = "a \"quoted\" \\ back\\slash"
    try Checks.require(AudioDriverInstaller.appleScriptLiteral(literal) == "\"a \\\"quoted\\\" \\\\ back\\\\slash\"", "AppleScript escaping differs")
    let script = AudioDriverInstaller.appleScript(command: quotedSource, prompt: "Babelfin \"test\"")
    try Checks.require(script.hasPrefix("do shell script \"") && script.hasSuffix("with administrator privileges"), "AppleScript form differs")
    var compileError: NSDictionary?
    try Checks.require(NSAppleScript(source: script)?.compileAndReturnError(&compileError) == true && compileError == nil, "generated AppleScript does not compile")
    // osascript returns the literal value; this proves the escaping round-trips. No shell command runs.
    let echoed = try shell("/usr/bin/osascript -e " + AudioDriverInstaller.shellQuote("return " + AudioDriverInstaller.appleScriptLiteral(quotedSource)))
    try Checks.require(echoed.trimmingCharacters(in: .newlines) == quotedSource, "AppleScript literal changed the command")
    print("PASS: install and remove commands quote every path, touch only the two bundles and compile as one AppleScript")
}

func driverDigestChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("babelfin-driver-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func makeBundle(_ base: URL, _ driver: AudioDriver, binary: String) throws {
        let contents = base.appendingPathComponent(driver.bundleName).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try Data(binary.utf8).write(to: contents.appendingPathComponent("MacOS/\(driver.name)"))
    }
    let bundled = root.appendingPathComponent("AudioDrivers"), hal = root.appendingPathComponent("HAL")
    try FileManager.default.createDirectory(at: hal, withIntermediateDirectories: true)
    for driver in AudioDriver.all { try makeBundle(bundled, driver, binary: driver.name) }
    let loaded: Set<String> = [AudioDevice.babelfinMicrophoneUID, AudioDevice.babelfinSpeakerUID]
    try Checks.require(AudioDriverStatus.evaluate(AudioDriverInstaller.observe(bundled: bundled, installedDirectory: hal, loadedUIDs: [])) == .notInstalled, "empty HAL folder not detected")
    for driver in AudioDriver.all { try makeBundle(hal, driver, binary: driver.name) }
    try Checks.require(AudioDriverStatus.evaluate(AudioDriverInstaller.observe(bundled: bundled, installedDirectory: hal, loadedUIDs: loaded)) == .installed, "identical bundles not detected")
    try Checks.require(AudioDriverStatus.evaluate(AudioDriverInstaller.observe(bundled: bundled, installedDirectory: hal, loadedUIDs: [])) == .notLoaded, "unloaded devices not detected")
    try Data("older build".utf8).write(to: hal.appendingPathComponent("Babelfin Speaker.driver/Contents/MacOS/Babelfin Speaker"))
    try Checks.require(AudioDriverStatus.evaluate(AudioDriverInstaller.observe(bundled: bundled, installedDirectory: hal, loadedUIDs: loaded)) == .versionDiffers, "changed binary not detected")
    let microphone = hal.appendingPathComponent("Babelfin Microphone.driver")
    let first = AudioDriverInstaller.digest(of: microphone)
    try FileManager.default.createSymbolicLink(atPath: microphone.appendingPathComponent("Contents/link").path, withDestinationPath: "/etc/hosts")
    try Checks.require(first != nil && AudioDriverInstaller.digest(of: microphone) != first, "symbolic link did not change the digest")
    try Checks.require(AudioDriverInstaller.digest(of: root.appendingPathComponent("missing.driver")) == nil, "missing bundle has a digest")
    try Checks.require(AudioDriverInstaller.observe(bundled: nil, installedDirectory: hal, loadedUIDs: loaded).allSatisfy { $0.bundledDigest == nil }, "absent app bundles reported a digest")
    print("PASS: bundle digests detect identical, changed, missing and linked driver files")
}
