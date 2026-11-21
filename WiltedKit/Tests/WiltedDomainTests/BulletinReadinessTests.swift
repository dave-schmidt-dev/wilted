import XCTest
import WiltedDomain

final class BulletinReadinessTests: XCTestCase {
    func testAllMissingStepsStayVisibleTogether() {
        let readiness = BulletinReadiness(hasNewsSource: false, hasWeatherLocation: false, soundCheckPaused: true)
        XCTAssertEqual(readiness.lines, [.news, .weather, .sound])
    }

    func testDisabledBulletinTypesDoNotRequireSetup() {
        let headlinesOnly = BulletinReadiness(hasNewsSource: true, hasWeatherLocation: false,
                                               soundCheckPaused: false, alertsEnabled: false)
        let weatherOnly = BulletinReadiness(hasNewsSource: false, hasWeatherLocation: true,
                                             soundCheckPaused: false, headlinesEnabled: false)
        XCTAssertEqual(headlinesOnly.lines, [.ready])
        XCTAssertEqual(weatherOnly.lines, [.ready])
    }

    func testUncheckedNewsNeverReportsMissingOrReady() {
        for hasNewsSource in [true, false] {
            XCTAssertEqual(BulletinReadiness(hasNewsSource: hasNewsSource, hasWeatherLocation: true,
                                             soundCheckPaused: false, newsCheck: .checking).lines, [.checkingNews])
            XCTAssertEqual(BulletinReadiness(hasNewsSource: hasNewsSource, hasWeatherLocation: true,
                                             soundCheckPaused: false, newsCheck: .unavailable).lines, [.unknownNews])
        }
    }

    func testBothBulletinTypesOffExplainsHowToStart() {
        let readiness = BulletinReadiness(hasNewsSource: true, hasWeatherLocation: true,
                                          soundCheckPaused: false, headlinesEnabled: false, alertsEnabled: false)
        XCTAssertEqual(readiness.lines, [.chooseSources])
    }
}
