import Foundation
import XCTest
@testable import AutoBrightnessCore

final class AmbientProtocolTests: XCTestCase {
  func testDecodesSample() throws {
    let bytes: [UInt8] = [
      1, 1, 0x34, 0x12,
      0x78, 0x56, 0x34, 0x12,
      0x40, 0xE2, 0x01, 0,
      0xCD, 0xAB, 3, 0,
    ]
    let sample = try XCTUnwrap(AmbientSample(data: Data(bytes)))
    XCTAssertEqual(sample.sequence, 0x1234)
    XCTAssertEqual(sample.uptimeMilliseconds, 0x12345678)
    XCTAssertEqual(sample.lux, 123.456, accuracy: 0.0001)
    XCTAssertEqual(sample.rawALS, 0xABCD)
    XCTAssertEqual(sample.range, 3)
  }

  func testCRCVector() {
    XCTAssertEqual(AmbientProtocol.crc16("123456789".utf8), 0x29B1)
  }
}
