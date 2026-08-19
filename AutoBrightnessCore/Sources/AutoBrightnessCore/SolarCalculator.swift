import Foundation

public struct SolarLocation: Codable, Equatable, Sendable, Identifiable {
  public var id: String { timeZoneIdentifier + ":\(latitude):\(longitude)" }
  public let name: String
  public let latitude: Double
  public let longitude: Double
  public let timeZoneIdentifier: String

  public init(
    name: String,
    latitude: Double,
    longitude: Double,
    timeZoneIdentifier: String
  ) {
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.timeZoneIdentifier = timeZoneIdentifier
  }

  public static let bundledCities = [
    SolarLocation(name: "Shanghai", latitude: 31.2304, longitude: 121.4737, timeZoneIdentifier: "Asia/Shanghai"),
    SolarLocation(name: "Beijing", latitude: 39.9042, longitude: 116.4074, timeZoneIdentifier: "Asia/Shanghai"),
    SolarLocation(name: "Shenzhen", latitude: 22.5431, longitude: 114.0579, timeZoneIdentifier: "Asia/Shanghai"),
    SolarLocation(name: "New York", latitude: 40.7128, longitude: -74.0060, timeZoneIdentifier: "America/New_York"),
    SolarLocation(name: "London", latitude: 51.5072, longitude: -0.1276, timeZoneIdentifier: "Europe/London"),
    SolarLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, timeZoneIdentifier: "Asia/Tokyo"),
  ]
}
public enum SolarEventKind: String, Codable, Sendable {
  case sunrise
  case sunset
}

public struct SolarEvent: Equatable, Sendable {
  public let kind: SolarEventKind
  public let date: Date
}

public enum SolarCalculator {
  public static func elevation(at date: Date, location: SolarLocation) -> Double {
    let julianDate = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    let days = julianDate - 2_451_545.0
    let meanLongitude = normalizeDegrees(280.460 + 0.9856474 * days)
    let meanAnomaly = radians(normalizeDegrees(357.528 + 0.9856003 * days))
    let eclipticLongitude = radians(
      normalizeDegrees(
        meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)
      )
    )
    let obliquity = radians(23.439 - 0.0000004 * days)
    let rightAscension = atan2(
      cos(obliquity) * sin(eclipticLongitude),
      cos(eclipticLongitude)
    )
    let declination = asin(sin(obliquity) * sin(eclipticLongitude))
    let gmstHours = 18.697374558 + 24.06570982441908 * days
    let localSiderealDegrees = normalizeDegrees(gmstHours * 15 + location.longitude)
    let hourAngle = radians(
      normalizeSignedDegrees(localSiderealDegrees - degrees(rightAscension))
    )
    let latitude = radians(location.latitude)
    return degrees(asin(
      sin(latitude) * sin(declination)
        + cos(latitude) * cos(declination) * cos(hourAngle)
    ))
  }

  public static func brightnessBias(
    at date: Date,
    location: SolarLocation,
    nightOffset: Double = -0.08
  ) -> Double {
    let altitude = elevation(at: date, location: location)
    if altitude <= -6 { return nightOffset }
    if altitude >= 6 { return 0 }
    let linear = (altitude + 6) / 12
    let smooth = linear * linear * (3 - 2 * linear)
    return nightOffset * (1 - smooth)
  }

  public static func nextEvent(
    after date: Date,
    location: SolarLocation
  ) -> SolarEvent? {
    let threshold = -0.833
    let step: TimeInterval = 5 * 60
    var previousDate = date
    var previous = elevation(at: previousDate, location: location) - threshold
    for increment in 1 ... 576 {
      let candidate = date.addingTimeInterval(Double(increment) * step)
      let current = elevation(at: candidate, location: location) - threshold
      if (previous < 0 && current >= 0) || (previous >= 0 && current < 0) {
        let fraction = abs(previous) / (abs(previous) + abs(current))
        return SolarEvent(
          kind: current >= 0 ? .sunrise : .sunset,
          date: previousDate.addingTimeInterval(step * fraction)
        )
      }
      previousDate = candidate
      previous = current
    }
    return nil
  }

  private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
  private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
  private static func normalizeDegrees(_ value: Double) -> Double {
    let result = value.truncatingRemainder(dividingBy: 360)
    return result < 0 ? result + 360 : result
  }
  private static func normalizeSignedDegrees(_ value: Double) -> Double {
    let normalized = normalizeDegrees(value)
    return normalized > 180 ? normalized - 360 : normalized
  }
}
