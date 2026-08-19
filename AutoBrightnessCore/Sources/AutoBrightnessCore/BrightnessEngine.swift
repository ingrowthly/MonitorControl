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
  private enum ChangeDirection {
    case brighter
    case dimmer
  }

  private static let logLuxDeadband = log10(1.2)
  private static let transientHoldInterval: TimeInterval = 20
  private static let brightenTimeConstant: TimeInterval = 30
  private static let dimTimeConstant: TimeInterval = 60

  private var logWindow: [Double] = []
  private var filteredLogLux: Double?
  private var lastTimestamp: Date?
  private var pendingDirection: ChangeDirection?
  private var pendingSince: Date?

  public init() {}

  public func reset() {
    logWindow.removeAll(keepingCapacity: true)
    filteredLogLux = nil
    lastTimestamp = nil
    pendingDirection = nil
    pendingSince = nil
  }

  public func ingest(_ sample: AmbientSample, at date: Date = Date()) -> FilteredAmbient? {
    guard sample.sensorOK, !sample.saturated, sample.lux.isFinite else { return nil }
    let logLux = log10(max(0, sample.lux) + 0.1)
    logWindow.append(logLux)
    if logWindow.count > 5 { logWindow.removeFirst() }
    let sorted = logWindow.sorted()
    let median = sorted[sorted.count / 2]

    if let previous = filteredLogLux, let lastTimestamp {
      let delta = median - previous
      guard abs(delta) > Self.logLuxDeadband else {
        pendingDirection = nil
        pendingSince = nil
        self.lastTimestamp = date
        return ambient(logLux: previous, at: date)
      }

      let direction: ChangeDirection = delta > 0 ? .brighter : .dimmer
      if pendingDirection != direction {
        pendingDirection = direction
        pendingSince = date
      }
      guard let pendingSince,
            date.timeIntervalSince(pendingSince) >= Self.transientHoldInterval
      else {
        self.lastTimestamp = date
        return ambient(logLux: previous, at: date)
      }

      let elapsed = min(max(date.timeIntervalSince(lastTimestamp), 0.01), 5)
      let timeConstant = direction == .brighter
        ? Self.brightenTimeConstant
        : Self.dimTimeConstant
      let alpha = 1 - exp(-elapsed / timeConstant)
      filteredLogLux = previous + alpha * delta
    } else {
      filteredLogLux = median
    }
    lastTimestamp = date
    return ambient(logLux: filteredLogLux ?? median, at: date)
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

  private func ambient(logLux: Double, at date: Date) -> FilteredAmbient {
    FilteredAmbient(lux: max(0, pow(10, logLux) - 0.1), timestamp: date)
  }
}

public struct BrightnessTransitionLimiter: Sendable {
  public let maximumChangePerSecond: Double

  private var value: Double?
  private var timestamp: Date?

  public init(maximumChangePerSecond: Double = 0.003) {
    self.maximumChangePerSecond = max(0, maximumChangePerSecond)
  }

  public mutating func reset(to value: Double? = nil, at date: Date? = nil) {
    self.value = value.map { min(1, max(0, $0)) }
    timestamp = value == nil ? nil : date
  }

  public mutating func step(
    toward target: Double,
    at date: Date,
    immediate: Bool = false
  ) -> Double {
    let boundedTarget = min(1, max(0, target))
    guard !immediate, let value, let timestamp else {
      value = boundedTarget
      timestamp = date
      return boundedTarget
    }

    let elapsed = min(max(date.timeIntervalSince(timestamp), 0), 5)
    let maximumChange = maximumChangePerSecond * elapsed
    let delta = min(max(boundedTarget - value, -maximumChange), maximumChange)
    let nextValue = value + delta
    self.value = nextValue
    self.timestamp = date
    return nextValue
  }
}
