import Foundation

public enum SensorTransportState: Equatable, Sendable {
  case stopped
  case searching
  case connected(name: String)
  case stale
  case failed(message: String)
}
public protocol AmbientSensorTransport: AnyObject {
  var onSample: ((AmbientSample) -> Void)? { get set }
  var onStateChange: ((SensorTransportState) -> Void)? { get set }
  func start()
  func stop()
}
