import Foundation

extension RegressionChecks {
    static func checkGPX() throws {
        let xml = """
            <gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
            <trkpt lat="10" lon="179"><ele>100</ele><time>2000-01-01T00:00:00.000Z</time></trkpt>
            <trkpt lat="12" lon="-179"><ele>120</ele><time>2000-01-01T00:00:10.000Z</time></trkpt>
            <trkpt lat="14" lon="-177"><ele>140</ele><time>2000-01-01T00:00:30.000Z</time></trkpt>
            </trkseg></trk></gpx>
            """
        func parse(_ input: String) throws -> GPXRoute {
            try GPXRoute.parse(Data(input.utf8), name: "Test")
        }
        let route = try parse(xml)
        assert(route.points.count == 3 && route.duration == 30)
        let equator = try GPXRoute(
            name: "Distance",
            points: [
                .init(fix: try LocationFix(latitude: 0, longitude: 179.999, altitude: 0, duration: 3600), offset: 0),
                .init(
                    fix: try LocationFix(latitude: 0, longitude: -179.999, altitude: 100, duration: 3600), offset: 100),
            ])
        assert(abs(equator.statistics.distance - 222.39016) < 0.01)
        assert(abs(equator.statistics.averageSpeed - 8.006046) < 0.001)
        assert(equator.statistics.activity == .running)
        let stationary = try GPXRoute(
            name: "Stationary",
            points: [
                .init(fix: equator.start, offset: 0), .init(fix: equator.start, offset: 100),
            ])
        assert(stationary.statistics.distance == 0 && stationary.statistics.averageSpeed == 0)
        assert(stationary.statistics.activity == .stationary)
        let halfway = route.fix(at: 5)
        assert(halfway.latitude == 11 && abs(halfway.longitude) == 180 && halfway.altitude == 110)
        assert(route.fix(at: 20).latitude == 13)
        assert(route.fix(at: 1_000_000).latitude == 14)
        let controller = SessionLocation(fix: route.start, route: route)
        assert(!controller.beginMovement())
        assert(controller.sample(at: 10).fix.latitude == 10)
        assert(controller.sample(at: 1000).fix.latitude == 10)  // Wait indefinitely at origin.
        controller.playRoute()
        _ = controller.sample(at: 1000)
        assert(controller.sample(at: 1005).fix.latitude == 11)
        controller.pauseRoute()
        assert(controller.sample(at: 5000).fix.latitude == 11)  // Keep sending the paused fix.
        assert(controller.routeSnapshot.state == .paused)
        controller.playRoute()
        assert(controller.sample(at: 5000).fix.latitude == 11)
        assert(controller.sample(at: 5005).fix.latitude == 12)
        controller.pause()  // iPhone subscription/reconnection gap must not advance playback.
        assert(controller.sample(at: 9000).fix.latitude == 12)
        assert(controller.sample(at: 9010).fix.latitude == 13)
        assert(controller.sample(at: 9020).fix.latitude == 14)
        assert(controller.routeSnapshot.state == .finished)
        controller.playRoute()  // No unexpected loop or restart at completion.
        assert(controller.sample(at: 1_000_000).fix.latitude == 14)
        assert(controller.routeSnapshot.state == .finished)
        let fresh = SessionLocation(fix: route.start, route: route)
        assert(fresh.routeSnapshot.state == .ready && fresh.sample(at: 0).fix.latitude == 10)
        for missingTag in ["", "<ele></ele>"] {
            do {
                _ = try parse(xml.replacingOccurrences(of: "<ele>100</ele>", with: missingTag))
                fatalError("Missing elevation silently imported")
            } catch let missing as GPXMissingElevations {
                assert(missing.indices == [0] && missing.route.points.count == 3)
                assert(missing.route.points[1].fix.altitude == 120)
            }
        }
        let routePoints = try parse(
            xml.replacingOccurrences(of: "<trk><trkseg>", with: "<rte>")
                .replacingOccurrences(of: "</trkseg></trk>", with: "</rte>")
                .replacingOccurrences(of: "trkpt", with: "rtept"))
        assert(routePoints.duration == 30)
        for invalid in [
            xml.replacingOccurrences(of: "lat=\"10\"", with: "lat=\"91\""),
            xml.replacingOccurrences(of: "lat=\"10\"", with: ""),
            xml.replacingOccurrences(of: "lon=\"179\"", with: ""),
            xml.replacingOccurrences(of: "lat=\"10\"", with: "lat=\"nan\""),
            xml.replacingOccurrences(of: "<ele>100</ele>", with: "<ele>100</ele><ele>200</ele>"),
            xml.replacingOccurrences(of: "<ele>100</ele>", with: "<ele>invalid</ele>"),
            xml.replacingOccurrences(of: "<time>2000-01-01T00:00:10.000Z</time>", with: "<time/>"),
            xml.replacingOccurrences(of: "<ele>100</ele>", with: "<ele>nan</ele>"),
            xml.replacingOccurrences(of: "00:00:10.000Z", with: "00:00:00.000Z"),
            xml.replacingOccurrences(of: "00:00:10.000Z", with: "not-a-date"),
            xml.replacingOccurrences(of: "<time>2000-01-01T00:00:10.000Z</time>", with: ""),
            xml.replacingOccurrences(of: "</trkseg>", with: "</trkseg><trkseg/>"),
            "<!DOCTYPE gpx [<!ENTITY e SYSTEM 'file:///etc/passwd'>]>" + xml,
            "<gpx/>", "<gpx><trk>",
        ] { expectFailure { _ = try parse(invalid) } }
        print(
            "GPX checks passed: relative timestamps, interpolation, altitude, dateline, start/pause/resume, subscription gaps, endpoint hold, malformed input."
        )
    }
}
