import CoreBluetooth
import Foundation

public final class BLEAmbientSensorTransport: NSObject, AmbientSensorTransport {
  public var onSample: ((AmbientSample) -> Void)?
  public var onStateChange: ((SensorTransportState) -> Void)?

  private static let serviceUUID = CBUUID(
    string: "7A1F0001-6B5C-4E4D-9F4A-1E2D3C4B5A60"
  )
  private static let telemetryUUID = CBUUID(
    string: "7A1F0002-6B5C-4E4D-9F4A-1E2D3C4B5A60"
  )

  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?

  public override init() {
    super.init()
  }

  public func start() {
    guard central == nil else { return }
    onStateChange?(.searching)
    central = CBCentralManager(delegate: self, queue: .main)
  }

  public func stop() {
    if let peripheral {
      central?.cancelPeripheralConnection(peripheral)
    }
    central?.stopScan()
    central = nil
    peripheral = nil
    onStateChange?(.stopped)
  }

  private func scan() {
    onStateChange?(.searching)
    central?.scanForPeripherals(
      withServices: [Self.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }
}
extension BLEAmbientSensorTransport: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      scan()
    case .unauthorized:
      onStateChange?(.failed(message: "Bluetooth permission denied"))
    case .poweredOff:
      onStateChange?(.failed(message: "Bluetooth is off"))
    default:
      onStateChange?(.searching)
    }
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData _: [String: Any],
    rssi _: NSNumber
  ) {
    self.peripheral = peripheral
    central.stopScan()
    peripheral.delegate = self
    central.connect(peripheral)
  }

  public func centralManager(
    _: CBCentralManager,
    didConnect peripheral: CBPeripheral
  ) {
    onStateChange?(.connected(name: peripheral.name ?? "AutoBrightness Sensor"))
    peripheral.discoverServices([Self.serviceUUID])
  }

  public func centralManager(
    _: CBCentralManager,
    didFailToConnect _: CBPeripheral,
    error: Error?
  ) {
    onStateChange?(.failed(message: error?.localizedDescription ?? "BLE connection failed"))
    scan()
  }

  public func centralManager(
    _: CBCentralManager,
    didDisconnectPeripheral _: CBPeripheral,
    error _: Error?
  ) {
    peripheral = nil
    scan()
  }
}

extension BLEAmbientSensorTransport: CBPeripheralDelegate {
  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverServices error: Error?
  ) {
    guard error == nil else {
      onStateChange?(.failed(message: error?.localizedDescription ?? "Service discovery failed"))
      return
    }
    for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
      peripheral.discoverCharacteristics([Self.telemetryUUID], for: service)
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil else {
      onStateChange?(.failed(message: error?.localizedDescription ?? "Characteristic discovery failed"))
      return
    }
    for characteristic in service.characteristics ?? []
      where characteristic.uuid == Self.telemetryUUID
    {
      peripheral.setNotifyValue(true, for: characteristic)
    }
  }

  public func peripheral(
    _: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, let data = characteristic.value,
          let sample = AmbientSample(data: data)
    else { return }
    onSample?(sample)
  }
}
