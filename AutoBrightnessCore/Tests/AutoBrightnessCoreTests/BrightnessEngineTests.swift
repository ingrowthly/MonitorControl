import Foundation
import XCTest
@testable import AutoBrightnessCore

final class BrightnessEngineTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000)

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

  func testShortAmbientDipIsRejected() throws {
    let engine = AutoBrightnessEngine()
    var sequence: UInt16 = 0
    var ambient: FilteredAmbient?

    for second in 0 ... 4 {
      ambient = engine.ingest(sample(lux: 500, sequence: &sequence), at: date(second))
    }
    for second in 5 ... 19 {
      ambient = engine.ingest(sample(lux: 100, sequence: &sequence), at: date(second))
    }
    for second in 20 ... 24 {
      ambient = engine.ingest(sample(lux: 500, sequence: &sequence), at: date(second))
    }

    XCTAssertEqual(try XCTUnwrap(ambient).lux, 500, accuracy: 0.001)
  }

  func testSustainedAmbientDipAdaptsGradually() throws {
    let engine = AutoBrightnessEngine()
    var sequence: UInt16 = 0
    var ambient: FilteredAmbient?

    for second in 0 ... 4 {
      ambient = engine.ingest(sample(lux: 500, sequence: &sequence), at: date(second))
    }
    for second in 5 ... 50 {
      ambient = engine.ingest(sample(lux: 100, sequence: &sequence), at: date(second))
    }

    let lux = try XCTUnwrap(ambient).lux
    XCTAssertLessThan(lux, 450)
    XCTAssertGreaterThan(lux, 150)
  }

  func testTransitionLimiterCapsBrightnessRate() {
    var limiter = BrightnessTransitionLimiter(maximumChangePerSecond: 0.003)

    XCTAssertEqual(limiter.step(toward: 0.8, at: date(0)), 0.8, accuracy: 0.0001)
    XCTAssertEqual(limiter.step(toward: 0.2, at: date(1)), 0.797, accuracy: 0.0001)
    XCTAssertEqual(limiter.step(toward: 0.2, at: date(2)), 0.794, accuracy: 0.0001)
    XCTAssertEqual(
      limiter.step(toward: 0.2, at: date(3), immediate: true),
      0.2,
      accuracy: 0.0001
    )
  }

  private func date(_ seconds: Int) -> Date {
    start.addingTimeInterval(TimeInterval(seconds))
  }

  private func sample(lux: Double, sequence: inout UInt16) -> AmbientSample {
    defer { sequence &+= 1 }
    return AmbientSample(
      sequence: sequence,
      uptimeMilliseconds: UInt32(sequence) * 1_000,
      milliLux: UInt32(lux * 1_000)
    )
  }
}
