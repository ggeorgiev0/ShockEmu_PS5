import Foundation
import ShockEmuCore
import Testing

private func profile(_ source: String) throws -> SEProfile {
    try SEProfile(data: Data(source.utf8))
}

@Test func profilePreservesOneToManyBindingsAndWarnsForExactDuplicates() throws {
    let parsed = try profile(
        """
        w = leftY-
        w = X
        w = X
        shift = O
        mouseLook.type = linear
        mouseLook.stick = right
        mouseLook.sensitivity = 0.05
        mouseLook.smoothing = 0.75
        mouseLook.minimumMagnitude = 0.85
        """
    )

    #expect(parsed.keyBindings[13] == ["leftY-", "X"])
    #expect(parsed.keyBindings[56] == ["O"])
    #expect(parsed.warnings.count == 1)
    #expect(parsed.mouseLookEnabled)
    #expect(parsed.mouseStick == "right")
    #expect(parsed.mouseSensitivity == 0.05)
    #expect(parsed.mouseSmoothing == 0.75)
    #expect(parsed.mouseMinimumMagnitude == 0.85)
}

@Test func profileRejectsUnknownActionsWithLineNumber() {
    #expect(throws: NSError.self) {
        _ = try profile("w = hyperdrive")
    }

    do {
        _ = try profile("# comment\nw = hyperdrive")
    } catch let error as NSError {
        #expect(error.domain == SEProfileErrorDomain)
        #expect(error.userInfo[NSLocalizedDescriptionKey] as? String == "Line 2: unknown action 'hyperdrive'")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func reportEncodesButtonsModifiersDpadAndAxes() throws {
    let engine = SEInputEngine(profile: try profile(
        """
        w = leftY-
        a = leftX-
        space = X
        shift = O
        up = dpadUp
        left = dpadLeft
        """
    ))
    engine.setKeyCode(13, pressed: true)
    engine.setKeyCode(0, pressed: true)
    engine.setKeyCode(49, pressed: true)
    engine.setKeyCode(56, pressed: true)
    engine.setKeyCode(126, pressed: true)
    engine.setKeyCode(123, pressed: true)

    let bytes = [UInt8](engine.copyInputReport())
    #expect(bytes.count == 64)
    #expect(bytes[0] == 0x01)
    #expect(bytes[1] == 1)
    #expect(bytes[2] == 1)
    #expect(bytes[5] == 0b0110_0111)
}

@Test func opposingAxesCancelAndMultipleInputsUseOrSemantics() throws {
    let engine = SEInputEngine(profile: try profile(
        """
        a = leftX-
        d = leftX+
        space = X
        enter = X
        """
    ))
    engine.setKeyCode(0, pressed: true)
    engine.setKeyCode(2, pressed: true)
    engine.setKeyCode(49, pressed: true)
    engine.setKeyCode(36, pressed: true)

    var bytes = [UInt8](engine.copyInputReport())
    #expect(bytes[1] == 128)
    #expect(bytes[5] & 0x20 == 0x20)

    engine.setKeyCode(49, pressed: false)
    bytes = [UInt8](engine.copyInputReport())
    #expect(bytes[5] & 0x20 == 0x20)
}

@Test func mouseOutputDependsOnTotalDeltaNotEventCount() throws {
    let parsed = try profile(
        """
        mouseLook.type = linear
        mouseLook.stick = right
        mouseLook.deadZone = 0
        mouseLook.sensitivity = 0.04
        mouseLook.smoothing = 1
        """
    )
    let singleEvent = SEInputEngine(profile: parsed)
    let splitEvents = SEInputEngine(profile: parsed)
    singleEvent.addMouseDeltaX(10, deltaY: -4)
    splitEvents.addMouseDeltaX(4, deltaY: -1)
    splitEvents.addMouseDeltaX(6, deltaY: -3)

    #expect(singleEvent.copyInputReport() == splitEvents.copyInputReport())
}

@Test func mouseMinimumMagnitudeSkipsSlowAnalogPanWithoutExtendingIdleTail() throws {
    let engine = SEInputEngine(profile: try profile(
        """
        mouseLook.type = linear
        mouseLook.stick = right
        mouseLook.deadZone = 0
        mouseLook.sensitivity = 0.01
        mouseLook.smoothing = 1
        mouseLook.minimumMagnitude = 0.85
        """
    ))
    engine.addMouseDeltaX(1, deltaY: 0)
    let moving = [UInt8](engine.copyInputReport())
    #expect(moving[3] >= 236)

    let idle = [UInt8](engine.copyInputReport())
    #expect(idle[3] <= 129)
}

@Test func clearImmediatelyReturnsNeutralReport() throws {
    let engine = SEInputEngine(profile: try profile("space = X"))
    engine.setKeyCode(49, pressed: true)
    engine.addMouseDeltaX(50, deltaY: 50)
    engine.clear()

    let bytes = [UInt8](engine.copyInputReport())
    #expect(bytes[1...4] == [128, 128, 128, 128])
    #expect(bytes[5] == 8)
    #expect(bytes[6] == 0)
}

@Test func featureReportsEnforceIdsAndBufferSizes() {
    var storage = [UInt8](repeating: 0, count: 64)
    var length = 1
    #expect(SECopyFeatureReport(0x12, &storage, &length) == .bufferTooSmall)
    #expect(length == 16)

    length = storage.count
    #expect(SECopyFeatureReport(0x12, &storage, &length) == .success)
    #expect(length == 16)
    #expect(storage[0] == 0x12)

    length = storage.count
    #expect(SECopyFeatureReport(0x99, &storage, &length) == .unsupported)
}

@Test func featureReportsMatchGoldenBytes() {
    let golden: [UInt8: [UInt8]] = [
        0x12: [0x12, 0x8b, 0x09, 0x07, 0x6d, 0x66, 0x1c, 0x08, 0x25, 0, 0, 0, 0, 0, 0, 0],
        0xa3: [
            0xa3, 0x41, 0x75, 0x67, 0x20, 0x20, 0x33, 0x20, 0x32, 0x30,
            0x31, 0x33, 0, 0, 0, 0, 0, 0x30, 0x37, 0x3a, 0x30, 0x31, 0x3a,
            0x31, 0x32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0x31, 3, 0, 0,
            0, 0x49, 0, 5, 0, 0, 0x80, 3, 0,
        ],
        0x02: [
            0x02, 1, 0, 0, 0, 0, 0, 0x87, 0x22, 0x7b, 0xdd, 0xb2, 0x22,
            0x47, 0xdd, 0xbd, 0x22, 0x43, 0xdd, 0x1c, 2, 0x1c, 2, 0x7f,
            0x1e, 0x2e, 0xdf, 0x60, 0x1f, 0x4c, 0xe0, 0x3a, 0x1d, 0xc6,
            0xde, 8, 0,
        ],
    ]
    for (id, expected) in golden {
        var bytes = [UInt8](repeating: 0, count: 64)
        var length = bytes.count
        #expect(SECopyFeatureReport(id, &bytes, &length) == .success)
        #expect(Array(bytes.prefix(length)) == expected)
    }
}

@Test func neutralInputReportMatchesGoldenBytes() throws {
    let bytes = [UInt8](SEInputEngine(profile: try profile("")).copyInputReport())
    let expected: [UInt8] = [
        1, 128, 128, 128, 128, 8, 0, 0, 0, 0, 0xc8, 0xad, 0xf9, 4, 0,
        0xfe, 0xff, 0xfc, 0xff, 0xe5, 0xfe, 0xcb, 0x1f, 0x69, 8, 0, 0, 0,
        0, 0, 0x1b, 0, 0, 1, 0x63, 0x8b, 0x80, 0xc1, 0x2e, 0x80,
    ] + [UInt8](repeating: 0, count: 24)
    #expect(bytes == expected)
}

@Test func simultaneousPhysicalModifiersDoNotReleaseLogicalShiftEarly() throws {
    let engine = SEInputEngine(profile: try profile("shift = O"))
    let modifiers = SEModifierState(inputEngine: engine)
    modifiers.togglePhysicalKeyCode(56)
    modifiers.togglePhysicalKeyCode(60)
    modifiers.togglePhysicalKeyCode(60)
    #expect([UInt8](engine.copyInputReport())[5] & 0x40 == 0x40)

    modifiers.togglePhysicalKeyCode(56)
    #expect([UInt8](engine.copyInputReport())[5] & 0x40 == 0)
}

@Test func repositoryProfilesRemainCompatible() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    for name in ["only_keyboard.se", "eldenring.se", "nomanssky.se"] {
        _ = try SEProfile(data: Data(contentsOf: repository.appendingPathComponent(name)))
    }
}

@Test func mouseCapturePolicyRestoresCursorAndRemembersManualToggle() {
    let policy = SEMouseCapturePolicy()
    #expect(policy.captureRequested)
    #expect(!policy.shouldCapture)

    policy.setStreamingActive(true)
    #expect(policy.shouldCapture)
    policy.toggleCaptureRequested()
    #expect(!policy.captureRequested)
    #expect(!policy.shouldCapture)

    policy.setStreamingActive(false)
    policy.setStreamingActive(true)
    #expect(!policy.shouldCapture)
    policy.toggleCaptureRequested()
    #expect(policy.shouldCapture)

    policy.setStreamingActive(false)
    #expect(!policy.shouldCapture)
}
