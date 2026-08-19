import Foundation

public struct BrightnessAnchor: Codable, Equatable, Sendable {
  public var lux: Double
  public var brightness: Double

  public init(lux: Double, brightness: Double) {
    self.lux = lux
    self.brightness = brightness
  }
}
public struct BrightnessProfile: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var minimum: Double
  public var maximum: Double
  public var anchors: [BrightnessAnchor]

  public init(
    enabled: Bool = true,
    minimum: Double = 0.05,
    maximum: Double = 1,
    anchors: [BrightnessAnchor] = Self.defaultAnchors
  ) {
    self.enabled = enabled
    self.minimum = minimum
    self.maximum = maximum
    self.anchors = anchors.sorted { $0.lux < $1.lux }
  }

  public static let defaultAnchors = [
    BrightnessAnchor(lux: 0.1, brightness: 0.05),
    BrightnessAnchor(lux: 1, brightness: 0.08),
    BrightnessAnchor(lux: 10, brightness: 0.18),
    BrightnessAnchor(lux: 50, brightness: 0.32),
    BrightnessAnchor(lux: 200, brightness: 0.48),
    BrightnessAnchor(lux: 500, brightness: 0.62),
    BrightnessAnchor(lux: 2_000, brightness: 0.80),
    BrightnessAnchor(lux: 10_000, brightness: 0.95),
    BrightnessAnchor(lux: 50_000, brightness: 1.00),
  ]
}

public struct FilteredAmbient: Equatable, Sendable {
  public let lux: Double
  public let timestamp: Date
}

public final class AutoBrightnessEngine {
  private var logWindow: [Double] = []
  private var filteredLogLux: Double?
  private var lastTimestamp: Date?

  public init() {}

  public func reset() {
    logWindow.removeAll(keepingCapacity: true)
    filteredLogLux = nil
    lastTimestamp = nil
  }

  public func ingest(_ sample: AmbientSample, at date: Date = Date()) -> FilteredAmbient? {
    guard sample.sensorOK, !sample.saturated, sample.lux.isFinite else { return nil }
    let logLux = log10(max(0, sample.lux) + 0.1)
    logWindow.append(logLux)
    if logWindow.count > 5 { logWindow.removeFirst() }
    let sorted = logWindow.sorted()
    let median = sorted[sorted.count / 2]

    if let previous = filteredLogLux, let lastTimestamp {
      let elapsed = min(max(date.timeIntervalSince(lastTimestamp), 0.01), 5)
      let timeConstant = median > previous ? 0.8 : 5.0
      let alpha = 1 - exp(-elapsed / timeConstant)
      filteredLogLux = previous + alpha * (median - previous)
    } else {
      filteredLogLux = median
    }
    lastTimestamp = date
    return FilteredAmbient(
      lux: max(0, pow(10, filteredLogLux ?? median) - 0.1),
      timestamp: date
    )
  }

  public func target(
    for ambient: FilteredAmbient,
    profile: BrightnessProfile,
    solarBias: Double
  ) -> Double? {
    guard profile.enabled, !profile.anchors.isEmpty else { return nil }
    let base = Self.interpolate(lux: ambient.lux, anchors: profile.anchors)
    return min(profile.maximum, max(profile.minimum, base + solarBias))
  }

  public static func learn(
    profile: inout BrightnessProfile,
    atLux lux: Double,
    selectedBrightness: Double,
    solarBias: Double
  ) {
    let desiredBase = min(1, max(0, selectedBrightness - solarBias))
    let current = interpolate(lux: lux, anchors: profile.anchors)
    let delta = desiredBase - current
    let center = log10(max(lux, 0) + 0.1)
    for index in profile.anchors.indices {
      let distance = log10(max(profile.anchors[index].lux, 0) + 0.1) - center
      let weight = exp(-(distance * distance) / (2 * 0.5 * 0.5))
      profile.anchors[index].brightness = min(
        1,
        max(0, profile.anchors[index].brightness + delta * weight)
      )
    }
    for index in profile.anchors.indices.dropFirst() {
      profile.anchors[index].brightness = max(
        profile.anchors[index].brightness,
        profile.anchors[index - 1].brightness
      )
    }
  }

  private static func interpolate(lux: Double, anchors: [BrightnessAnchor]) -> Double {
    let sorted = anchors.sorted { $0.lux < $1.lux }
    guard let first = sorted.first, let last = sorted.last else { return 0 }
    if lux <= first.lux { return first.brightness }
    if lux >= last.lux { return last.brightness }
    for pair in zip(sorted, sorted.dropFirst()) where lux <= pair.1.lux {
      let lowerLog = log10(pair.0.lux + 0.1)
      let upperLog = log10(pair.1.lux + 0.1)
      let fraction = (log10(lux + 0.1) - lowerLog) / (upperLog - lowerLog)
      return pair.0.brightness
        + fraction * (pair.1.brightness - pair.0.brightness)
    }
    return last.brightness
  }
}
