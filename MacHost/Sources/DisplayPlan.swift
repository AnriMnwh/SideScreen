/// Virtual-display geometry that matches a client's presentation area 1:1.
///
/// The client reports the pixels it shows video in, in its CURRENT orientation
/// (type 15). The host display is created/re-moded at exactly that physical
/// size, so no scaling happens on either side. HiDPI (2×) is used when the
/// resulting logical desktop is still a usable size; below that, small phones
/// get a 1× desktop instead of a cramped one. Orientation is taken as given:
/// in match mode the client owns rotation, the host applies none.
struct DisplayPlan: Equatable {
    /// Logical desktop size (points).
    let logicalWidth: Int
    let logicalHeight: Int
    let hiDPI: Bool
    /// Pixels the display renders: logical × 2 with HiDPI, else logical.
    let physicalWidth: Int
    let physicalHeight: Int

    /// Smallest logical desktop (short side × long side) a 2× plan may produce.
    static let minHiDPILogicalShort = 480
    static let minHiDPILogicalLong = 640

    static func resolve(presentationWidth: Int, presentationHeight: Int, hiDPIRequested: Bool) -> DisplayPlan {
        // 4:2:0 encode needs even dimensions; never go below 2×2.
        let width = max(presentationWidth & ~1, 2)
        let height = max(presentationHeight & ~1, 2)
        let useHiDPI = hiDPIRequested
            && min(width, height) / 2 >= minHiDPILogicalShort
            && max(width, height) / 2 >= minHiDPILogicalLong
        if useHiDPI {
            let logicalWidth = width / 2
            let logicalHeight = height / 2
            return DisplayPlan(logicalWidth: logicalWidth, logicalHeight: logicalHeight, hiDPI: true,
                               physicalWidth: logicalWidth * 2, physicalHeight: logicalHeight * 2)
        }
        return DisplayPlan(logicalWidth: width, logicalHeight: height, hiDPI: false,
                           physicalWidth: width, physicalHeight: height)
    }
}
