import Darwin
import Dispatch
import Foundation
import IOKit
import IOKit.serial

public final class USBAmbientSensorTransport: AmbientSensorTransport, @unchecked Sendable {
  public var onSample: ((AmbientSample) -> Void)?
  public var onStateChange: ((SensorTransportState) -> Void)?

  private let queue = DispatchQueue(label: "AutoBrightness.USBTransport")
  private var descriptor: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var reconnectTimer: DispatchSourceTimer?
  private var decoder = SerialFrameDecoder()
  private var running = false
  private let expectedSerialNumber: String?

  public init(expectedSerialNumber: String? = nil) {
    self.expectedSerialNumber = expectedSerialNumber
  }

  public func start() {
    queue.async { [weak self] in
      guard let self, !self.running else { return }
      self.running = true
      self.emit(.searching)
      self.openIfAvailable()
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now() + 1, repeating: 1)
      timer.setEventHandler { [weak self] in self?.openIfAvailable() }
      self.reconnectTimer = timer
      timer.resume()
    }
  }

  public func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.running = false
      self.reconnectTimer?.cancel()
      self.reconnectTimer = nil
      self.closePort()
      self.emit(.stopped)
    }
  }

  private func openIfAvailable() {
    guard running, descriptor < 0,
          let path = Self.espressifSerialPaths(
            expectedSerialNumber: expectedSerialNumber
          ).first
    else {
      return
    }
    let fd = Darwin.open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
      emit(.failed(message: "Unable to open \(path)"))
      return
    }

    var options = termios()
    if tcgetattr(fd, &options) == 0 {
      cfmakeraw(&options)
      _ = cfsetspeed(&options, speed_t(B115200))
      options.c_cflag |= tcflag_t(CLOCAL | CREAD)
      _ = tcsetattr(fd, TCSANOW, &options)
    }

    descriptor = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.readAvailableBytes() }
    source.setCancelHandler { Darwin.close(fd) }
    readSource = source
    source.resume()
    emit(.connected(name: URL(fileURLWithPath: path).lastPathComponent))
  }

  private func readAvailableBytes() {
    guard descriptor >= 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 256)
    let count = Darwin.read(descriptor, &bytes, bytes.count)
    if count > 0 {
      let samples = decoder.append(Data(bytes.prefix(count)))
      for sample in samples {
        DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
      }
    } else if count == 0 || errno != EAGAIN {
      closePort()
      emit(.searching)
    }
  }

  private func closePort() {
    if let source = readSource {
      source.cancel()
      readSource = nil
    } else if descriptor >= 0 {
      Darwin.close(descriptor)
    }
    descriptor = -1
  }

  private func emit(_ state: SensorTransportState) {
    DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
  }

  public static func espressifSerialPaths(
    expectedSerialNumber: String? = nil
  ) -> [String] {
    var iterator: io_iterator_t = 0
    let mainPort: mach_port_t
    if #available(macOS 12.0, *) {
      mainPort = kIOMainPortDefault
    } else {
      mainPort = kIOMasterPortDefault
    }
    guard
      let matching = IOServiceMatching("IOSerialBSDClient"),
      IOServiceGetMatchingServices(mainPort, matching, &iterator)
        == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }

    var paths: [String] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard
        let vendor = registryValue(service, key: "idVendor") as? NSNumber,
        vendor.intValue == 0x303A,
        let product = registryValue(service, key: "idProduct") as? NSNumber,
        product.intValue == 0x1001,
        expectedSerialNumber == nil
          || (registryValue(service, key: "USB Serial Number") as? String)
            == expectedSerialNumber,
        let path = IORegistryEntryCreateCFProperty(
          service,
          kIOCalloutDeviceKey as CFString,
          kCFAllocatorDefault,
          0
        )?.takeRetainedValue() as? String
      else { continue }
      paths.append(path)
    }
    return paths.sorted()
  }

  private static func registryValue(_ service: io_service_t, key: String) -> Any? {
    IORegistryEntrySearchCFProperty(
      service,
      kIOServicePlane,
      key as CFString,
      kCFAllocatorDefault,
      IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    )
  }
}
