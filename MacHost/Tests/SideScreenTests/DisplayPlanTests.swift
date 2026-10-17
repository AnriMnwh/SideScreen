import XCTest
@testable import SideScreen

final class DisplayPlanTests: XCTestCase {
    private func plan(_ w: Int, _ h: Int, hiDPI: Bool = true) -> DisplayPlan {
        DisplayPlan.resolve(presentationWidth: w, presentationHeight: h, hiDPIRequested: hiDPI)
    }

    private func assertPlan(
        _ p: DisplayPlan, logical: (Int, Int), physical: (Int, Int), hiDPI: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(p.logicalWidth, logical.0, "logical width", file: file, line: line)
        XCTAssertEqual(p.logicalHeight, logical.1, "logical height", file: file, line: line)
        XCTAssertEqual(p.physicalWidth, physical.0, "physical width", file: file, line: line)
        XCTAssertEqual(p.physicalHeight, physical.1, "physical height", file: file, line: line)
        XCTAssertEqual(p.hiDPI, hiDPI, "hiDPI", file: file, line: line)
    }

    // MARK: - Foldable inner panel, both orientations

    func testFoldInnerLandscape() {
        assertPlan(plan(2448, 1848), logical: (1224, 924), physical: (2448, 1848), hiDPI: true)
    }

    func testFoldInnerPortrait() {
        assertPlan(plan(1848, 2448), logical: (924, 1224), physical: (1848, 2448), hiDPI: true)
    }

    // MARK: - Phone, both orientations (orientation kept as given)

    func testPhonePortrait() {
        assertPlan(plan(1080, 2340), logical: (540, 1170), physical: (1080, 2340), hiDPI: true)
    }

    func testPhoneLandscape() {
        assertPlan(plan(2340, 1080), logical: (1170, 540), physical: (2340, 1080), hiDPI: true)
    }

    func testRetroidPocket6() {
        assertPlan(plan(1920, 1080), logical: (960, 540), physical: (1920, 1080), hiDPI: true)
    }

    // MARK: - 1× below the HiDPI floor

    func testSmallPhoneFallsBackTo1x() {
        // 720×1600 at 2× would be a 360×800 desktop: short side below 480.
        assertPlan(plan(720, 1600), logical: (720, 1600), physical: (720, 1600), hiDPI: false)
    }

    func testLongSideBelowFloorFallsBackTo1x() {
        // 1000×1200 at 2× is 500×600: long side below 640.
        assertPlan(plan(1000, 1200), logical: (1000, 1200), physical: (1000, 1200), hiDPI: false)
    }

    func testExactHiDPIFloorStays2x() {
        assertPlan(plan(960, 1280), logical: (480, 640), physical: (960, 1280), hiDPI: true)
    }

    func testHiDPINotRequestedIs1x() {
        assertPlan(plan(2340, 1080, hiDPI: false), logical: (2340, 1080), physical: (2340, 1080), hiDPI: false)
    }

    // MARK: - Odd dimensions are floored to even

    func testOddDimensionsFlooredToEven2x() {
        assertPlan(plan(2341, 1081), logical: (1170, 540), physical: (2340, 1080), hiDPI: true)
    }

    func testOddDimensionsFlooredToEven1x() {
        assertPlan(plan(721, 1601), logical: (720, 1600), physical: (720, 1600), hiDPI: false)
    }

    func testPhysicalAlwaysEven() {
        for (w, h) in [(2342, 1082), (1847, 2449), (2223, 1001), (1, 1), (0, 0)] {
            for hiDPI in [true, false] {
                let p = plan(w, h, hiDPI: hiDPI)
                XCTAssertEqual(p.physicalWidth % 2, 0, "\(w)x\(h)")
                XCTAssertEqual(p.physicalHeight % 2, 0, "\(w)x\(h)")
                XCTAssertGreaterThan(p.physicalWidth, 0)
                XCTAssertGreaterThan(p.physicalHeight, 0)
                XCTAssertEqual(p.physicalWidth, p.hiDPI ? p.logicalWidth * 2 : p.logicalWidth)
                XCTAssertEqual(p.physicalHeight, p.hiDPI ? p.logicalHeight * 2 : p.logicalHeight)
            }
        }
    }

    // MARK: - Stream format description

    func testStreamFormatDescriptionHDR10() {
        XCTAssertEqual(
            DisplaySettings.describeStreamFormat(.hdr10, fps: 120, width: 2340, height: 1080),
            "HDR10 · 10-bit · 120 fps · 2340×1080")
    }

    func testStreamFormatDescriptionSDR() {
        XCTAssertEqual(
            DisplaySettings.describeStreamFormat(.sdr709, fps: 60, width: 1920, height: 1080),
            "SDR · 8-bit · 60 fps · 1920×1080")
    }

    // MARK: - Re-mode read-back

    func testHiDPIReModeNeedsPixelSizeNotATransientOneXMode() {
        // Transient 1× mode right after apply: logical size matches, pixels do not.
        XCTAssertFalse(VirtualDisplayManager.modeMatches(size: (1170, 540), pixels: (1170, 540),
                                                         requested: (1170, 540), hiDPI: true))
        XCTAssertTrue(VirtualDisplayManager.modeMatches(size: (1170, 540), pixels: (2340, 1080),
                                                        requested: (1170, 540), hiDPI: true))
        // WindowServer's default after apply on macOS 27: 1920×1080 points at 1×, whose pixel
        // count equals the 960×540@2× request but whose desktop is twice as large.
        XCTAssertFalse(VirtualDisplayManager.modeMatches(size: (1920, 1080), pixels: (1920, 1080),
                                                         requested: (960, 540), hiDPI: true))
    }

    func testOneXReModeNeedsRawSize() {
        XCTAssertTrue(VirtualDisplayManager.modeMatches(size: (2340, 1080), pixels: (2340, 1080),
                                                        requested: (2340, 1080), hiDPI: false))
        XCTAssertFalse(VirtualDisplayManager.modeMatches(size: (1170, 540), pixels: (2340, 1080),
                                                         requested: (2340, 1080), hiDPI: false))
    }

    // MARK: - Orientation ownership

    func testHostKeepsRotationForClientsWithoutPanelAdvert() {
        let transform = DisplayTransformSettings(matchDevice: true, rotation: 90, flipHorizontal: false, flipVertical: false)
        XCTAssertEqual(transform.hostRotation(clientAdvertisesPanel: false), 90)
        XCTAssertFalse(transform.clientOwnsOrientation(clientAdvertisesPanel: false))
        XCTAssertEqual(transform.hostRotation(clientAdvertisesPanel: true), 0)
        XCTAssertTrue(transform.clientOwnsOrientation(clientAdvertisesPanel: true))

        let manual = DisplayTransformSettings(matchDevice: false, rotation: 270, flipHorizontal: false, flipVertical: false)
        XCTAssertEqual(manual.hostRotation(clientAdvertisesPanel: true), 270)
        XCTAssertFalse(manual.clientOwnsOrientation(clientAdvertisesPanel: true))
    }
}
