import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Schedule linear timeline viewport")
struct ScheduleTimelineViewportTests {
    @Test("Initial position centers the current time")
    func initialPositionCentersCurrentTime() {
        let viewport = ScheduleTimelineViewport.initial(
            viewportHeight: 780,
            scale: CGFloat(24) / CGFloat(13),
            currentMinute: 14 * 60 + 30
        )

        let visibleCenterMinute = (viewport.offsetY + viewport.viewportHeight / 2)
            / viewport.contentHeight * CGFloat(24 * 60)
        #expect(abs(visibleCenterMinute - CGFloat(14 * 60 + 30)) < 0.001)
    }

    @Test("Initial position clamps at both day boundaries")
    func initialPositionClampsAtDayBoundaries() {
        let morning = ScheduleTimelineViewport.initial(
            viewportHeight: 780,
            scale: 2,
            currentMinute: 60
        )
        let evening = ScheduleTimelineViewport.initial(
            viewportHeight: 780,
            scale: 2,
            currentMinute: 23 * 60
        )

        #expect(morning.offsetY == 0)
        #expect(evening.offsetY == evening.contentHeight - evening.viewportHeight)
    }

    @Test("Zoom keeps a stationary finger center on the same minute")
    func zoomPreservesStationaryAnchor() {
        let initial = ScheduleTimelineViewport(
            viewportHeight: 780,
            scale: 1.5,
            offsetY: 260
        )
        let anchorY: CGFloat = 310
        let anchoredRatio = (initial.offsetY + anchorY) / initial.contentHeight
        let zoomed = initial.zoomed(
            to: 2.4,
            initialAnchorY: anchorY,
            currentAnchorY: anchorY
        )

        let zoomedRatio = (zoomed.offsetY + anchorY) / zoomed.contentHeight
        #expect(abs(zoomedRatio - anchoredRatio) < 0.001)
    }

    @Test("Zoom follows a moving finger center")
    func zoomTracksMovingAnchor() {
        let initial = ScheduleTimelineViewport(
            viewportHeight: 780,
            scale: 1.5,
            offsetY: 240
        )
        let anchoredRatio = (initial.offsetY + 280) / initial.contentHeight
        let zoomed = initial.zoomed(
            to: 2.2,
            initialAnchorY: 280,
            currentAnchorY: 430
        )

        let zoomedRatio = (zoomed.offsetY + 430) / zoomed.contentHeight
        #expect(abs(zoomedRatio - anchoredRatio) < 0.001)
    }

    @Test("Zoom scale and offsets stay inside supported bounds")
    func zoomClampsScaleAndOffsets() {
        let top = ScheduleTimelineViewport(viewportHeight: 780, scale: 1, offsetY: 0)
            .zoomed(to: 0.1, initialAnchorY: 0, currentAnchorY: 600)
        let bottom = ScheduleTimelineViewport(viewportHeight: 780, scale: 3, offsetY: 1_560)
            .zoomed(to: 8, initialAnchorY: 780, currentAnchorY: 0)

        #expect(top.scale == ScheduleTimelineViewport.minimumScale)
        #expect(top.offsetY == 0)
        #expect(bottom.scale == ScheduleTimelineViewport.maximumScale)
        #expect(bottom.offsetY == bottom.contentHeight - bottom.viewportHeight)
    }

    @Test("Continuous zoom updates keep the original minute under the fingers")
    func continuousZoomPreservesAnchor() {
        let initial = ScheduleTimelineViewport(
            viewportHeight: 780,
            scale: CGFloat(24) / CGFloat(13),
            offsetY: 430
        )
        let initialAnchorY: CGFloat = 360
        let anchoredRatio = (initial.offsetY + initialAnchorY) / initial.contentHeight
        let updates: [(scale: CGFloat, anchorY: CGFloat)] = [
            (2.0, 350),
            (2.25, 330),
            (2.6, 315),
            (2.15, 340),
            (1.9, 365),
        ]

        for update in updates {
            let viewport = initial.zoomed(
                to: update.scale,
                initialAnchorY: initialAnchorY,
                currentAnchorY: update.anchorY
            )
            let currentRatio = (viewport.offsetY + update.anchorY) / viewport.contentHeight
            #expect(abs(currentRatio - anchoredRatio) < 0.001)
            #expect(viewport.offsetY > 0)
        }
    }
}

