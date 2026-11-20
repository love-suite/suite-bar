import CoreGraphics
import Testing
@testable import ExplorerCore

@Suite struct WindowOverviewTests {
    let area = CGRect(x: 0, y: 0, width: 1400, height: 900)

    @Test func framesStayInsideWithoutOverlapAndKeepShapes() {
        let sizes = [CGSize(width: 1200, height: 800), CGSize(width: 600, height: 900), CGSize(width: 800, height: 500),
                     CGSize(width: 1400, height: 900), CGSize(width: 300, height: 300)]
        let frames = OverviewLayout.frames(for: sizes, in: area)
        #expect(frames.count == 5)
        for (frame, size) in zip(frames, sizes) {
            #expect(area.contains(frame))
            #expect(abs(frame.width / frame.height - size.width / size.height) < 0.02)
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                #expect(!frames[i].intersects(frames[j]))
            }
        }
    }

    @Test func smallWindowsAreNeverEnlarged() {
        let frames = OverviewLayout.frames(for: [CGSize(width: 200, height: 100)], in: area)
        #expect(frames.first?.size == CGSize(width: 200, height: 100))
    }

    @Test func uniformWindowsAllFillTheirCells() {
        let sizes = [CGSize(width: 1400, height: 900), CGSize(width: 300, height: 200), CGSize(width: 800, height: 500),
                     CGSize(width: 600, height: 400)]
        let frames = OverviewLayout.frames(for: sizes, in: area, uniform: true)
        // Each one fills its cell, across or down: the small window is enlarged like the others.
        let widest = frames.map(\.width).max() ?? 0
        let tallest = frames.map(\.height).max() ?? 0
        for frame in frames {
            #expect(abs(frame.width - widest) <= 2 || abs(frame.height - tallest) <= 2)
        }
        #expect(frames[1].width > 300)
        for i in frames.indices {
            #expect(area.contains(frames[i]))
            for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
        }
    }

    @Test func nothingToShowGivesNothing() {
        #expect(OverviewLayout.frames(for: [], in: area).isEmpty)
    }

    @Test func arrowsMoveInReadingOrderAndBetweenRows() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 200, y: 0, width: 100, height: 100),
                      CGRect(x: 0, y: 200, width: 100, height: 100), CGRect(x: 200, y: 200, width: 100, height: 100)]
        #expect(OverviewLayout.neighbour(of: 0, count: 4, frames: frames, direction: .right) == 1)
        #expect(OverviewLayout.neighbour(of: 0, count: 4, frames: frames, direction: .left) == 3)
        #expect(OverviewLayout.neighbour(of: 1, count: 4, frames: frames, direction: .down) == 3)
        #expect(OverviewLayout.neighbour(of: 2, count: 4, frames: frames, direction: .up) == 0)
        #expect(OverviewLayout.neighbour(of: 0, count: 4, frames: frames, direction: .up) == 0)
    }

    @Test func onlyRealWindowsAreShown() {
        let screens = CGRect(x: 0, y: 0, width: 1470, height: 956)
        #expect(OverviewWindow.isShown(layer: 0, alpha: 1, frame: CGRect(x: 10, y: 40, width: 800, height: 600),
                                       screens: screens))
        #expect(!OverviewWindow.isShown(layer: 20, alpha: 1, frame: CGRect(x: 10, y: 40, width: 800, height: 600),
                                        screens: screens))
        #expect(!OverviewWindow.isShown(layer: 0, alpha: 0, frame: CGRect(x: 10, y: 40, width: 800, height: 600),
                                        screens: screens))
        #expect(!OverviewWindow.isShown(layer: 0, alpha: 1, frame: CGRect(x: 10, y: 40, width: 30, height: 20),
                                        screens: screens))
        // Parked in the bottom right corner by our minimize.
        #expect(!OverviewWindow.isShown(layer: 0, alpha: 1, frame: CGRect(x: 1469, y: 955, width: 800, height: 600),
                                        screens: screens))
    }

    @Test func windowsAreMatchedByPlaceAndSize() {
        let candidates = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 100, y: 50, width: 800, height: 600)]
        #expect(WindowMatch.index(of: CGRect(x: 101, y: 50, width: 800, height: 599), in: candidates) == 1)
        #expect(WindowMatch.index(of: CGRect(x: 300, y: 50, width: 800, height: 600), in: candidates) == nil)
    }
}
