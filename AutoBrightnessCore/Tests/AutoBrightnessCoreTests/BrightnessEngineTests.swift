import Foundation
import XCTest
@testable import AutoBrightnessCore

final class BrightnessEngineTests: XCTestCase {
  func testCurveIsBounded() throws {
    let engine = AutoBrightnessEngine()
    let sample = AmbientSample(
      sequence: 1,
      uptimeMilliseconds: 1_000,
      milliLux: 200_000
    )
    let ambient = try XCTUnwrap(engine.ingest(sample, at: Date()))
    let profile = BrightnessProfile(minimum: 0.2, maximum: 0.4)
    let target = try XCTUnwrap(
      engine.target(for: ambient, profile: profile, solarBias: 0)
    )
    XCTAssertEqual(target, 0.4, accuracy: 0.0001)
  }

  func testLearningKeepsCurveMonotonic() {
    var profile = BrightnessProfile()
    AutoBrightnessEngine.learn(
      profile: &profile,
      atLux: 50,
      selectedBrightness: 0.8,
      solarBias: -0.08
    )
    for pair in zip(profile.anchors, profile.anchors.dropFirst()) {
      XCTAssertLessThanOrEqual(pair.0.brightness, pair.1.brightness)
    }
  }
}
