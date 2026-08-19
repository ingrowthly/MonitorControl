//  Copyright (c) 2026 MonitorControl contributors

import AppKit
import AutoBrightnessCore
import Foundation
import os.log

final class AutoBrightnessCoordinator: NSObject {
  private enum PreferenceKey {
    static let enabled = "autoBrightness.enabled"
    static let nightOffset = "autoBrightness.nightOffset"
    static let profilePrefix = "autoBrightness.profile."
  }

  private enum TransportKind: String {
    case bluetooth = "Bluetooth"
    case usb = "USB"
  }

  private let bluetoothTransport = BLEAmbientSensorTransport()
  private let usbTransport = USBAmbientSensorTransport(
    expectedSerialNumber: "E8:F6:0A:14:37:90"
  )
  private let engine = AutoBrightnessEngine()
  private let location = SolarLocation.bundledCities[0]
  private let staleInterval: TimeInterval = 3
  private let manualHoldInterval: TimeInterval = 10
  private let minimumApplyInterval: TimeInterval = 1
  private let minimumBrightnessChange: Float = 0.005

  private var bluetoothState: SensorTransportState = .stopped
  private var usbState: SensorTransportState = .stopped
  private var lastBluetoothSampleDate: Date?
  private var lastUSBSampleDate: Date?
  private var lastSampleDate: Date?
  private var activeTransport: TransportKind?
  private var filteredAmbient: FilteredAmbient?
  private var lastApplyDate: Date?
  private var lastAppliedBrightness: [String: Float] = [:]
  private var transitionLimiters: [String: BrightnessTransitionLimiter] = [:]
  private var manualHoldUntil: [String: Date] = [:]
  private var profiles: [String: BrightnessProfile] = [:]
  private var timer: Timer?
  private var isSleeping = false
  private var isReconfiguring = false
  private var conflictingApplications: [String] = []

  private weak var toggleMenuItem: NSMenuItem?
  private weak var statusMenuItem: NSMenuItem?

  var isEnabled: Bool {
    get { prefs.bool(forKey: PreferenceKey.enabled) }
    set {
      prefs.set(newValue, forKey: PreferenceKey.enabled)
      if newValue {
        applyCurrentAmbient(force: true)
      }
      updateMenuPresentation()
    }
  }

  var nightOffset: Double {
    get { prefs.double(forKey: PreferenceKey.nightOffset) }
    set {
      prefs.set(min(0, max(-0.2, newValue)), forKey: PreferenceKey.nightOffset)
      applyCurrentAmbient(force: true)
      updateMenuPresentation()
    }
  }

  override init() {
    super.init()
    prefs.register(defaults: [
      PreferenceKey.enabled: false,
      PreferenceKey.nightOffset: -0.08,
    ])
    configureTransports()
  }

  func start() {
    bluetoothTransport.start()
    usbTransport.start()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.timerFired()
    }
    timerFired()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    bluetoothTransport.stop()
    usbTransport.stop()
    engine.reset()
    filteredAmbient = nil
    lastSampleDate = nil
    activeTransport = nil
    transitionLimiters.removeAll()
  }

  func setSleeping(_ sleeping: Bool) {
    isSleeping = sleeping
    if !sleeping {
      engine.reset()
      filteredAmbient = nil
      lastSampleDate = nil
    }
    updateMenuPresentation()
  }

  func displayConfigurationWillChange() {
    isReconfiguring = true
    updateMenuPresentation()
  }

  func displaysDidReconfigure() {
    isReconfiguring = false
    lastAppliedBrightness.removeAll()
    transitionLimiters.removeAll()
    applyCurrentAmbient(force: true)
    updateMenuPresentation()
  }

  func manualBrightnessChanged(display: Display, value: Float) {
    guard !isSleeping, !isReconfiguring else { return }
    let now = Date()
    let key = stableDisplayID(display)
    manualHoldUntil[key] = now.addingTimeInterval(manualHoldInterval)
    lastAppliedBrightness[key] = value
    var limiter = transitionLimiters[key] ?? BrightnessTransitionLimiter()
    limiter.reset(to: Double(value), at: now)
    transitionLimiters[key] = limiter

    guard let ambient = filteredAmbient,
          let sampleDate = lastSampleDate,
          now.timeIntervalSince(sampleDate) <= staleInterval
    else {
      updateMenuPresentation()
      return
    }

    var profile = profile(for: display)
    AutoBrightnessEngine.learn(
      profile: &profile,
      atLux: ambient.lux,
      selectedBrightness: Double(value),
      solarBias: currentSolarBias(at: now)
    )
    profiles[key] = profile
    save(profile: profile, key: key)
    os_log(
      "Learned auto brightness for %{public}@ at %{public}.1f lux: %{public}.2f",
      type: .info,
      display.name,
      ambient.lux,
      value
    )
    updateMenuPresentation()
  }

  func addMenuItems(to menu: NSMenu) {
    menu.addItem(.separator())

    let toggle = NSMenuItem(
      title: "Automatic Brightness",
      action: #selector(toggleAutomaticBrightness(_:)),
      keyEquivalent: ""
    )
    toggle.target = self
    toggleMenuItem = toggle
    menu.addItem(toggle)

    let status = NSMenuItem(title: statusTitle(), action: nil, keyEquivalent: "")
    status.isEnabled = false
    statusMenuItem = status
    menu.addItem(status)

    let nightItem = NSMenuItem(title: "Night Bias", action: nil, keyEquivalent: "")
    let nightMenu = NSMenu(title: "Night Bias")
    for percent in [0, -4, -8, -12, -16] {
      let item = NSMenuItem(
        title: percent == 0 ? "Off" : "\(percent)%",
        action: #selector(selectNightOffset(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = NSNumber(value: Double(percent) / 100)
      item.state = abs(nightOffset - Double(percent) / 100) < 0.001 ? .on : .off
      nightMenu.addItem(item)
    }
    nightItem.submenu = nightMenu
    menu.addItem(nightItem)

    let displaysItem = NSMenuItem(title: "Automatic Displays", action: nil, keyEquivalent: "")
    let displaysMenu = NSMenu(title: "Automatic Displays")
    let displays = DisplayManager.shared.sortDisplaysByFriendlyName().filter { !$0.isDummy }
    if displays.isEmpty {
      let item = NSMenuItem(title: "No displays", action: nil, keyEquivalent: "")
      item.isEnabled = false
      displaysMenu.addItem(item)
    } else {
      for display in displays {
        let item = NSMenuItem(
          title: display.name,
          action: #selector(toggleDisplay(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = stableDisplayID(display)
        item.state = profile(for: display).enabled ? .on : .off
        displaysMenu.addItem(item)
      }
    }
    displaysItem.submenu = displaysMenu
    menu.addItem(displaysItem)

    updateMenuPresentation()
  }

  @objc private func toggleAutomaticBrightness(_ sender: NSMenuItem) {
    isEnabled.toggle()
    sender.state = isEnabled ? .on : .off
  }

  @objc private func selectNightOffset(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? NSNumber else { return }
    nightOffset = value.doubleValue
    menu.updateMenus()
  }

  @objc private func toggleDisplay(_ sender: NSMenuItem) {
    guard let key = sender.representedObject as? String,
          let display = DisplayManager.shared.displays.first(where: { stableDisplayID($0) == key })
    else { return }
    var profile = profile(for: display)
    profile.enabled.toggle()
    profiles[key] = profile
    save(profile: profile, key: key)
    sender.state = profile.enabled ? .on : .off
    applyCurrentAmbient(force: true)
  }

  private func configureTransports() {
    bluetoothTransport.onStateChange = { [weak self] state in
      self?.bluetoothState = state
      self?.updateMenuPresentation()
    }
    usbTransport.onStateChange = { [weak self] state in
      self?.usbState = state
      self?.updateMenuPresentation()
    }
    bluetoothTransport.onSample = { [weak self] sample in
      self?.receive(sample, from: .bluetooth)
    }
    usbTransport.onSample = { [weak self] sample in
      self?.receive(sample, from: .usb)
    }
  }

  private func receive(_ sample: AmbientSample, from transport: TransportKind) {
    let now = Date()
    switch transport {
    case .bluetooth:
      lastBluetoothSampleDate = now
    case .usb:
      lastUSBSampleDate = now
      if bluetoothIsFresh(at: now) { return }
    }

    activeTransport = transport
    lastSampleDate = now
    guard let ambient = engine.ingest(sample, at: now) else {
      updateMenuPresentation()
      return
    }
    filteredAmbient = ambient
    applyCurrentAmbient(at: now)
    updateMenuPresentation()
  }

  private func timerFired() {
    updateConflictingApplications()
    let now = Date()
    if activeTransport == .bluetooth, !bluetoothIsFresh(at: now), usbIsFresh(at: now) {
      activeTransport = .usb
      lastSampleDate = lastUSBSampleDate
      engine.reset()
      filteredAmbient = nil
    }
    applyCurrentAmbient(at: now)
    updateMenuPresentation()
  }

  private func applyCurrentAmbient(at now: Date = Date(), force: Bool = false) {
    guard isEnabled,
          !isSleeping,
          !isReconfiguring,
          conflictingApplications.isEmpty,
          let ambient = filteredAmbient,
          let sampleDate = lastSampleDate,
          now.timeIntervalSince(sampleDate) <= staleInterval
    else { return }

    if !force, let lastApplyDate,
       now.timeIntervalSince(lastApplyDate) < minimumApplyInterval
    {
      return
    }

    let solarBias = currentSolarBias(at: now)
    for display in DisplayManager.shared.displays where !display.isDummy {
      let key = stableDisplayID(display)
      if let holdUntil = manualHoldUntil[key], holdUntil > now { continue }
      let profile = profile(for: display)
      guard let target = engine.target(
        for: ambient,
        profile: profile,
        solarBias: solarBias
      ) else { continue }
      var limiter = transitionLimiters[key] ?? BrightnessTransitionLimiter()
      let limitedTarget = limiter.step(toward: target, at: now, immediate: force)
      transitionLimiters[key] = limiter
      let value = Float(limitedTarget)
      if !force, let previous = lastAppliedBrightness[key],
         abs(previous - value) < minimumBrightnessChange
      {
        continue
      }
      if display.setBrightness(value) {
        lastAppliedBrightness[key] = value
        display.sliderHandler[.brightness]?.setValue(value, displayID: display.identifier)
      }
    }
    lastApplyDate = now
  }

  private func currentSolarBias(at date: Date) -> Double {
    SolarCalculator.brightnessBias(at: date, location: location, nightOffset: nightOffset)
  }

  private func bluetoothIsFresh(at date: Date) -> Bool {
    guard case .connected = bluetoothState, let lastBluetoothSampleDate else { return false }
    return date.timeIntervalSince(lastBluetoothSampleDate) <= staleInterval
  }

  private func usbIsFresh(at date: Date) -> Bool {
    guard case .connected = usbState, let lastUSBSampleDate else { return false }
    return date.timeIntervalSince(lastUSBSampleDate) <= staleInterval
  }

  private func updateConflictingApplications() {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let conflicts = NSWorkspace.shared.runningApplications.compactMap { application -> String? in
      guard application.processIdentifier != ownPID,
            let identifier = application.bundleIdentifier,
            Self.conflictingBundleIdentifiers.contains(identifier)
      else { return nil }
      return application.localizedName ?? identifier
    }
    conflictingApplications = Array(Set(conflicts)).sorted()
  }

  private static let conflictingBundleIdentifiers: Set<String> = [
    "app.monitorcontrol.MonitorControl",
    "me.waydabber.BetterDisplay",
    "pro.betterdisplay.BetterDisplay",
  ]

  private func statusTitle(at date: Date = Date()) -> String {
    if !isEnabled { return "Sensor: automatic control is off" }
    if isSleeping { return "Paused: display is sleeping" }
    if isReconfiguring { return "Paused: displays are reconfiguring" }
    if !conflictingApplications.isEmpty {
      return "Paused: quit \(conflictingApplications.joined(separator: ", "))"
    }
    guard let sampleDate = lastSampleDate,
          date.timeIntervalSince(sampleDate) <= staleInterval,
          let ambient = filteredAmbient,
          let activeTransport
    else {
      return "Sensor: \(searchStateDescription())"
    }
    let lux = ambient.lux < 10
      ? String(format: "%.1f", ambient.lux)
      : String(format: "%.0f", ambient.lux)
    let bias = Int((currentSolarBias(at: date) * 100).rounded())
    let solar = bias == 0 ? "daylight" : "solar \(bias)%"
    return "Sensor: \(activeTransport.rawValue) · \(lux) lx · \(solar)"
  }

  private func searchStateDescription() -> String {
    if case let .failed(message) = bluetoothState,
       case let .failed(usbMessage) = usbState
    {
      return "Bluetooth: \(message); USB: \(usbMessage)"
    }
    if lastSampleDate != nil { return "data is stale" }
    if case let .failed(message) = bluetoothState { return "USB searching; \(message)" }
    if case let .failed(message) = usbState { return "Bluetooth searching; \(message)" }
    return "searching via Bluetooth and USB"
  }

  private func updateMenuPresentation() {
    toggleMenuItem?.state = isEnabled ? .on : .off
    statusMenuItem?.title = statusTitle()
  }

  private func stableDisplayID(_ display: Display) -> String {
    let vendor = display.vendorNumber ?? 0
    let model = display.modelNumber ?? 0
    let serial = display.serialNumber ?? 0
    let fallback = serial == 0 ? display.name.filter { !$0.isWhitespace } : ""
    return "\(vendor)-\(model)-\(serial)-\(fallback)"
  }

  private func profile(for display: Display) -> BrightnessProfile {
    let key = stableDisplayID(display)
    if let cached = profiles[key] { return cached }
    if let data = prefs.data(forKey: PreferenceKey.profilePrefix + key),
       let stored = try? JSONDecoder().decode(BrightnessProfile.self, from: data)
    {
      profiles[key] = stored
      return stored
    }
    let profile = BrightnessProfile()
    profiles[key] = profile
    return profile
  }

  private func save(profile: BrightnessProfile, key: String) {
    guard let data = try? JSONEncoder().encode(profile) else { return }
    prefs.set(data, forKey: PreferenceKey.profilePrefix + key)
  }
}
