import AutoBrightnessCore
import Foundation

let useBluetooth = CommandLine.arguments.contains("--bluetooth")
let duration = CommandLine.arguments
  .first { $0.hasPrefix("--seconds=") }
  .flatMap { Double($0.dropFirst("--seconds=".count)) } ?? 10

let transport: AmbientSensorTransport = useBluetooth
  ? BLEAmbientSensorTransport()
  : USBAmbientSensorTransport(expectedSerialNumber: "E8:F6:0A:14:37:90")

var sampleCount = 0
transport.onStateChange = { state in
  switch state {
  case .stopped:
    print("state=stopped")
  case .searching:
    print("state=searching")
  case let .connected(name):
    print("state=connected device=\(name)")
  case .stale:
    print("state=stale")
  case let .failed(message):
    print("state=failed error=\(message)")
  }
}
transport.onSample = { sample in
  sampleCount += 1
  print(
    String(
      format: "sample=%u lux=%.3f raw=%u range=%u flags=0x%02X",
      sample.sequence,
      sample.lux,
      sample.rawALS,
      sample.range,
      sample.flags
    )
  )
}

transport.start()
RunLoop.main.run(until: Date().addingTimeInterval(duration))
transport.stop()

if sampleCount == 0 {
  fputs("No valid ambient samples received.\n", stderr)
  exit(1)
}
