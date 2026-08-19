import Foundation
import XCTest
@testable import AutoBrightnessCore

final class SolarCalculatorTests: XCTestCase {
  private let shanghai = SolarLocation.bundledCities[0]

  func testNoonIsAboveMidnight() throws {
    let formatter = ISO8601DateFormatter()
    let noon = try XCTUnwrap(formatter.date(from: "2026-06-21T04:00:00Z"))
    let midnight = try XCTUnwrap(formatter.date(from: "2026-06-21T16:00:00Z"))
    XCTAssertGreaterThan(
      SolarCalculator.elevation(at: noon, location: shanghai),
      SolarCalculator.elevation(at: midnight, location: shanghai)
    )
    XCTAssertEqual(
      SolarCalculator.brightnessBias(at: noon, location: shanghai),
      0,
      accuracy: 0.001
    )
    XCTAssertEqual(
      SolarCalculator.brightnessBias(at: midnight, location: shanghai),
      -0.08,
      accuracy: 0.001
    )
  }

  func testFindsNextSolarEvent() throws {
    let formatter = ISO8601DateFormatter()
    let date = try XCTUnwrap(formatter.date(from: "2026-06-21T00:00:00Z"))
    XCTAssertNotNil(SolarCalculator.nextEvent(after: date, location: shanghai))
  }
}
