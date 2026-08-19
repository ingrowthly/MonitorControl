import Foundation

public struct AmbientSample: Equatable, Sendable {
  public static let wireSize = 16
  public static let currentVersion: UInt8 = 1

  public let version: UInt8
  public let flags: UInt8
  public let sequence: UInt16
  public let uptimeMilliseconds: UInt32
  public let milliLux: UInt32
  public let rawALS: UInt16
  public let range: UInt8

  public var lux: Double { Double(milliLux) / 1_000 }
  public var sensorOK: Bool { flags & 0x01 != 0 }
  public var rangeChanged: Bool { flags & 0x02 != 0 }
  public var saturated: Bool { flags & 0x04 != 0 }

  public init?(data: Data) {
    guard data.count == Self.wireSize else { return nil }
    let bytes = [UInt8](data)
    guard bytes[0] == Self.currentVersion else { return nil }
    version = bytes[0]
    flags = bytes[1]
    sequence = Self.u16(bytes, 2)
    uptimeMilliseconds = Self.u32(bytes, 4)
    milliLux = Self.u32(bytes, 8)
    rawALS = Self.u16(bytes, 12)
    range = bytes[14]
  }

  public init(
    flags: UInt8 = 1,
    sequence: UInt16,
    uptimeMilliseconds: UInt32,
    milliLux: UInt32,
    rawALS: UInt16 = 0,
    range: UInt8 = 0
  ) {
    version = Self.currentVersion
    self.flags = flags
    self.sequence = sequence
    self.uptimeMilliseconds = uptimeMilliseconds
    self.milliLux = milliLux
    self.rawALS = rawALS
    self.range = range
  }

  private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
public enum AmbientProtocol {
  public static let telemetryPacket: UInt8 = 1

  public static func crc16(_ bytes: some Collection<UInt8>) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
      crc ^= UInt16(byte) << 8
      for _ in 0 ..< 8 {
        crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
      }
    }
    return crc
  }

  public static func decodeCOBS(_ encoded: [UInt8]) -> [UInt8]? {
    var output: [UInt8] = []
    var index = 0
    while index < encoded.count {
      let code = Int(encoded[index])
      guard code > 0 else { return nil }
      index += 1
      guard index + code - 1 <= encoded.count else { return nil }
      if code > 1 {
        output.append(contentsOf: encoded[index ..< index + code - 1])
        index += code - 1
      }
      if code != 0xFF, index < encoded.count {
        output.append(0)
      }
    }
    return output
  }
}

public struct SerialFrameDecoder: Sendable {
  private var buffer: [UInt8] = []

  public init() {}

  public mutating func append(_ data: Data) -> [AmbientSample] {
    var samples: [AmbientSample] = []
    for byte in data {
      if byte != 0 {
        if buffer.count < 128 {
          buffer.append(byte)
        } else {
          buffer.removeAll(keepingCapacity: true)
        }
        continue
      }

      defer { buffer.removeAll(keepingCapacity: true) }
      guard
        !buffer.isEmpty,
        let decoded = AmbientProtocol.decodeCOBS(buffer),
        decoded.count == AmbientSample.wireSize + 3,
        decoded[0] == AmbientProtocol.telemetryPacket
      else { continue }

      let expectedCRC = UInt16(decoded[decoded.count - 2])
        | UInt16(decoded[decoded.count - 1]) << 8
      guard AmbientProtocol.crc16(decoded.dropLast(2)) == expectedCRC else {
        continue
      }
      if let sample = AmbientSample(data: Data(decoded[1 ..< 17])) {
        samples.append(sample)
      }
    }
    return samples
  }
}
