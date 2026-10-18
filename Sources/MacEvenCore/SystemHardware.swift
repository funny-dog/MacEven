import Foundation
import Darwin
import IOKit
import IOKit.ps
import Metal
import SystemConfiguration

// MARK: - CPU Models

public struct CoreCPUCounters: Sendable, Equatable, Hashable {
    public let coreIndex: Int
    public let user: UInt64
    public let system: UInt64
    public let nice: UInt64
    public let idle: UInt64

    public init(coreIndex: Int, user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.coreIndex = coreIndex
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }

    public var totalTicks: UInt64 {
        let (s1, o1) = user.addingReportingOverflow(system)
        let (s2, o2) = s1.addingReportingOverflow(nice)
        let (s3, o3) = s2.addingReportingOverflow(idle)
        guard !o1, !o2, !o3 else { return 0 }
        return s3
    }
}

public struct CoreCPULoad: Sendable, Equatable {
    public let coreIndex: Int
    public let counters: CoreCPUCounters
    public let usagePercent: Double?

    public init(coreIndex: Int, counters: CoreCPUCounters, usagePercent: Double?) {
        self.coreIndex = coreIndex
        self.counters = counters
        self.usagePercent = usagePercent
    }
}

public struct CPUHardwareSnapshot: Sendable {
    public let model: String
    public let architecture: String
    public let physicalCores: Int
    public let logicalCores: Int
    public let performanceCores: Int?
    public let efficiencyCores: Int?
    public let cores: [CoreCPULoad]
    public let unavailableReason: String?

    public init(
        model: String,
        architecture: String,
        physicalCores: Int,
        logicalCores: Int,
        performanceCores: Int? = nil,
        efficiencyCores: Int? = nil,
        cores: [CoreCPULoad] = [],
        unavailableReason: String? = nil
    ) {
        self.model = model
        self.architecture = architecture
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.cores = cores
        self.unavailableReason = unavailableReason
    }
}

// MARK: - Memory Pressure Models

public enum MemoryPressureLevel: String, Sendable, Codable {
    case normal = "normal"
    case warning = "warning"
    case critical = "critical"
    case unknown = "unknown"

    public static func from(rawLevel: Int) -> MemoryPressureLevel {
        switch rawLevel {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }
}

public struct SystemMemoryPressure: Sendable {
    public let level: MemoryPressureLevel
    public let rawVMPressureLevel: Int?
    public let memorystatusLevelPercentage: Int?
    public let pagesFree: UInt64
    public let pagesActive: UInt64
    public let pagesInactive: UInt64
    public let pagesWired: UInt64
    public let pagesPurgeable: UInt64
    public let pagesCompressed: UInt64
    public let pageins: UInt64
    public let pageouts: UInt64
    public let source: String
    public let unavailableReason: String?

    public init(
        level: MemoryPressureLevel,
        rawVMPressureLevel: Int?,
        memorystatusLevelPercentage: Int?,
        pagesFree: UInt64,
        pagesActive: UInt64,
        pagesInactive: UInt64,
        pagesWired: UInt64,
        pagesPurgeable: UInt64,
        pagesCompressed: UInt64,
        pageins: UInt64,
        pageouts: UInt64,
        source: String = "kern.memorystatus + mach.host_statistics64",
        unavailableReason: String? = nil
    ) {
        self.level = level
        self.rawVMPressureLevel = rawVMPressureLevel
        self.memorystatusLevelPercentage = memorystatusLevelPercentage
        self.pagesFree = pagesFree
        self.pagesActive = pagesActive
        self.pagesInactive = pagesInactive
        self.pagesWired = pagesWired
        self.pagesPurgeable = pagesPurgeable
        self.pagesCompressed = pagesCompressed
        self.pageins = pageins
        self.pageouts = pageouts
        self.source = source
        self.unavailableReason = unavailableReason
    }
}

// MARK: - GPU Models

public struct GPUSnapshot: Sendable {
    public let model: String
    public let coreCount: Int?
    public let deviceUtilizationPercent: Double?
    public let rendererUtilizationPercent: Double?
    public let tilerUtilizationPercent: Double?
    public let inUseSystemMemoryBytes: UInt64?
    public let allocatedPBSizeBytes: UInt64?
    public let ioClass: String?
    public let unavailableReason: String?

    public init(
        model: String,
        coreCount: Int? = nil,
        deviceUtilizationPercent: Double? = nil,
        rendererUtilizationPercent: Double? = nil,
        tilerUtilizationPercent: Double? = nil,
        inUseSystemMemoryBytes: UInt64? = nil,
        allocatedPBSizeBytes: UInt64? = nil,
        ioClass: String? = nil,
        unavailableReason: String? = nil
    ) {
        self.model = model
        self.coreCount = coreCount
        self.deviceUtilizationPercent = deviceUtilizationPercent
        self.rendererUtilizationPercent = rendererUtilizationPercent
        self.tilerUtilizationPercent = tilerUtilizationPercent
        self.inUseSystemMemoryBytes = inUseSystemMemoryBytes
        self.allocatedPBSizeBytes = allocatedPBSizeBytes
        self.ioClass = ioClass
        self.unavailableReason = unavailableReason
    }
}

// MARK: - Thermal & Fan Models

public enum ThermalState: String, Sendable, Codable {
    case nominal = "nominal"
    case fair = "fair"
    case serious = "serious"
    case critical = "critical"
    case unknown = "unknown"

    public static func from(processInfoState: ProcessInfo.ThermalState) -> ThermalState {
        switch processInfoState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}

public struct SMCThermalSnapshot: Sendable {
    public let fanSpeedsRPM: [Double]
    public let fanCount: Int?
    public let temperaturesCelsius: [String: Double]
    public let isAvailable: Bool
    public let unavailableReason: String?

    public init(
        fanSpeedsRPM: [Double] = [],
        temperaturesCelsius: [String: Double] = [:],
        isAvailable: Bool = false,
        unavailableReason: String? = nil,
        fanCount: Int? = nil
    ) {
        self.fanSpeedsRPM = fanSpeedsRPM
        self.fanCount = fanCount
        self.temperaturesCelsius = temperaturesCelsius
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
    }
}

// MARK: - Battery Models

public struct BatterySnapshot: Sendable {
    public let isInstalled: Bool
    public let currentCapacityPercent: Int?
    public let isCharging: Bool?
    public let isACConnected: Bool?
    public let powerSourceState: String?
    public let condition: String?
    public let cycleCount: Int?
    public let currentCapacitymAh: Int?
    public let maxCapacitymAh: Int?
    public let voltageMilliVolts: Int?
    public let amperageMilliAmps: Int?
    public let watts: Double?
    public let unavailableReason: String?

    public init(
        isInstalled: Bool,
        currentCapacityPercent: Int? = nil,
        isCharging: Bool? = nil,
        isACConnected: Bool? = nil,
        powerSourceState: String? = nil,
        condition: String? = nil,
        cycleCount: Int? = nil,
        currentCapacitymAh: Int? = nil,
        maxCapacitymAh: Int? = nil,
        voltageMilliVolts: Int? = nil,
        amperageMilliAmps: Int? = nil,
        watts: Double? = nil,
        unavailableReason: String? = nil
    ) {
        self.isInstalled = isInstalled
        self.currentCapacityPercent = currentCapacityPercent
        self.isCharging = isCharging
        self.isACConnected = isACConnected
        self.powerSourceState = powerSourceState
        self.condition = condition
        self.cycleCount = cycleCount
        self.currentCapacitymAh = currentCapacitymAh
        self.maxCapacitymAh = maxCapacitymAh
        self.voltageMilliVolts = voltageMilliVolts
        self.amperageMilliAmps = amperageMilliAmps
        self.watts = watts
        self.unavailableReason = unavailableReason
    }
}

// MARK: - Bluetooth Accessory Models

public struct BluetoothAccessorySnapshot: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let batteryPercent: Int?
    public let caseBatteryPercent: Int?
    public let leftBatteryPercent: Int?
    public let rightBatteryPercent: Int?
    public let isCharging: Bool?
    public let deviceAddress: String?
    public let source: String

    public init(
        id: String,
        name: String,
        batteryPercent: Int? = nil,
        caseBatteryPercent: Int? = nil,
        leftBatteryPercent: Int? = nil,
        rightBatteryPercent: Int? = nil,
        isCharging: Bool? = nil,
        deviceAddress: String? = nil,
        source: String
    ) {
        self.id = id
        self.name = name
        self.batteryPercent = batteryPercent
        self.caseBatteryPercent = caseBatteryPercent
        self.leftBatteryPercent = leftBatteryPercent
        self.rightBatteryPercent = rightBatteryPercent
        self.isCharging = isCharging
        self.deviceAddress = deviceAddress
        self.source = source
    }
}

// MARK: - Network Interface Models

public struct NetworkInterfaceDetail: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let ipv4Addresses: [String]
    public let ipv4Netmasks: [String]
    public let ipv6Addresses: [String]
    public let isUp: Bool
    public let isLoopback: Bool
    public let isPointToPoint: Bool
    public let isVPN: Bool
    public let flags: UInt32

    public init(
        name: String,
        ipv4Addresses: [String] = [],
        ipv4Netmasks: [String] = [],
        ipv6Addresses: [String] = [],
        isUp: Bool = false,
        isLoopback: Bool = false,
        isPointToPoint: Bool = false,
        isVPN: Bool = false,
        flags: UInt32 = 0
    ) {
        self.name = name
        self.ipv4Addresses = ipv4Addresses
        self.ipv4Netmasks = ipv4Netmasks
        self.ipv6Addresses = ipv6Addresses
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
        self.isVPN = isVPN
        self.flags = flags
    }
}

// MARK: - Hardware Snapshot

public struct HardwareSnapshot: Sendable {
    public let sampledAt: Date
    public let sampledUptime: TimeInterval
    public let sampleDurationSeconds: Double
    public let cpu: CPUHardwareSnapshot
    public let memoryPressure: SystemMemoryPressure
    public let gpu: [GPUSnapshot]
    public let thermalState: ThermalState
    public let smcThermal: SMCThermalSnapshot
    public let battery: BatterySnapshot
    public let bluetoothAccessories: [BluetoothAccessorySnapshot]
    public let bluetoothiOSUnavailableReason: String
    public let networkInterfaces: [NetworkInterfaceDetail]
    public let unavailableReasons: [String: String]

    public init(
        sampledAt: Date,
        sampleDurationSeconds: Double,
        cpu: CPUHardwareSnapshot,
        memoryPressure: SystemMemoryPressure,
        gpu: [GPUSnapshot],
        thermalState: ThermalState,
        smcThermal: SMCThermalSnapshot,
        battery: BatterySnapshot,
        bluetoothAccessories: [BluetoothAccessorySnapshot],
        bluetoothiOSUnavailableReason: String,
        networkInterfaces: [NetworkInterfaceDetail],
        unavailableReasons: [String: String] = [:],
        sampledUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.sampledAt = sampledAt
        self.sampledUptime = sampledUptime
        self.sampleDurationSeconds = sampleDurationSeconds
        self.cpu = cpu
        self.memoryPressure = memoryPressure
        self.gpu = gpu
        self.thermalState = thermalState
        self.smcThermal = smcThermal
        self.battery = battery
        self.bluetoothAccessories = bluetoothAccessories
        self.bluetoothiOSUnavailableReason = bluetoothiOSUnavailableReason
        self.networkInterfaces = networkInterfaces
        self.unavailableReasons = unavailableReasons
    }
}

extension HardwareSnapshot {
    public func temperature(gpu: Bool = false) -> Double? {
        let readings = smcThermal.temperaturesCelsius.filter {
            gpu ? $0.key.hasPrefix("Tg") || $0.key.hasPrefix("TG") : $0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te") || $0.key.hasPrefix("Tf") || $0.key.hasPrefix("TC")
        }.values.filter { $0.isFinite && $0 > 0 && $0 <= 150 }
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }
}

// MARK: - SystemHardware Sampler

// Mutable native state belongs to one serial sampling queue.
public final class SystemHardware {
    private var previousCPUCounters: [Int: CoreCPUCounters] = [:]
    private var smc: SMCReader?
    private var thermalKeys: [String] = []
    private var smcRetryAt: TimeInterval = 0
    private var smcError: String?

    public init() {}
    public static func capacityPercent(current: Int, maximum: Int) -> Int? {
        guard maximum > 0, current >= 0, current <= maximum else { return nil }
        return Int(Double(current) / Double(maximum) * 100)
    }
    public static func validPercent(_ value: Double) -> Double? { value.isFinite && (0...100).contains(value) ? value : nil }

    public func resetBaselines() {
        previousCPUCounters.removeAll(keepingCapacity: true)
        smc = nil; thermalKeys = []; smcRetryAt = 0; smcError = nil
    }

    public func sample() -> HardwareSnapshot {
        let startTime = ProcessInfo.processInfo.systemUptime
        let sampledDate = Date()
        var unavailableReasons: [String: String] = [:]

        // 1. CPU
        let cpuSnapshot = sampleCPU()
        if let reason = cpuSnapshot.unavailableReason {
            unavailableReasons["cpu"] = reason
        }

        // 2. Memory Pressure (system kernel source, not used/total)
        let memPressure = sampleMemoryPressure()
        if let reason = memPressure.unavailableReason {
            unavailableReasons["memoryPressure"] = reason
        }

        // 3. GPU
        let gpus = sampleGPU()
        for (idx, g) in gpus.enumerated() {
            if let reason = g.unavailableReason {
                unavailableReasons["gpu[\(idx)]"] = reason
            }
        }

        // 4. Thermal & SMC
        let thermalState = ThermalState.from(processInfoState: ProcessInfo.processInfo.thermalState)
        let smcThermal = sampleSMCThermal()
        if let reason = smcThermal.unavailableReason {
            unavailableReasons["smc"] = reason
        }

        // 5. Battery
        let battery = sampleBattery()
        if let reason = battery.unavailableReason {
            unavailableReasons["battery"] = reason
        }

        // 6. Bluetooth Accessories
        let btAccessories = sampleBluetoothAccessories()
        let btIOSUnavailableReason = localized("尚未接入配对 iPhone/iPad 的电量来源；这里仅显示 IORegistry 可读取的配件电量。")
        unavailableReasons["bluetooth_ios"] = btIOSUnavailableReason

        // 7. Network Interfaces
        let networks = sampleNetworkInterfaces()

        let duration = ProcessInfo.processInfo.systemUptime - startTime

        return HardwareSnapshot(
            sampledAt: sampledDate,
            sampleDurationSeconds: duration,
            cpu: cpuSnapshot,
            memoryPressure: memPressure,
            gpu: gpus,
            thermalState: thermalState,
            smcThermal: smcThermal,
            battery: battery,
            bluetoothAccessories: btAccessories,
            bluetoothiOSUnavailableReason: btIOSUnavailableReason,
            networkInterfaces: networks,
            unavailableReasons: unavailableReasons,
            sampledUptime: startTime
        )
    }

    // MARK: - CPU Sampler

    private func sampleCPU() -> CPUHardwareSnapshot {
        let model = readSysctlString("machdep.cpu.brand_string") ?? readSysctlString("hw.model") ?? localized("硬件型号未知")
        let arch = readSysctlString("hw.machine") ?? {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }()
        let physicalCores = readSysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let logicalCores = readSysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let pCores = readSysctlInt("hw.perflevel0.physicalcpu")
        let eCores = readSysctlInt("hw.perflevel1.physicalcpu")

        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return CPUHardwareSnapshot(
                model: model,
                architecture: arch,
                physicalCores: physicalCores,
                logicalCores: logicalCores,
                performanceCores: pCores,
                efficiencyCores: eCores,
                cores: [],
                unavailableReason: "host_processor_info failed with kern_return_t: \(kr)"
            )
        }

        let infoSize = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), infoSize) }
        let coreCount = min(Int(numCPUsU), Int(numCpuInfo) / Int(CPU_STATE_MAX), 4096)
        var coreLoads: [CoreCPULoad] = []
        var nextCounters: [Int: CoreCPUCounters] = [:]

        for coreIdx in 0..<coreCount {
            let base = coreIdx * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)]))

            let current = CoreCPUCounters(coreIndex: coreIdx, user: user, system: system, nice: nice, idle: idle)
            nextCounters[coreIdx] = current

            var usagePercent: Double? = nil
            if let previous = previousCPUCounters[coreIdx] {
                let (dUser, u1) = current.user.subtractingReportingOverflow(previous.user)
                let (dSystem, u2) = current.system.subtractingReportingOverflow(previous.system)
                let (dNice, u3) = current.nice.subtractingReportingOverflow(previous.nice)
                let (dIdle, u4) = current.idle.subtractingReportingOverflow(previous.idle)

                if !u1 && !u2 && !u3 && !u4 {
                    let dBusy = dUser + dSystem + dNice
                    let dTotal = dBusy + dIdle
                    if dTotal > 0 {
                        let pct = (Double(dBusy) / Double(dTotal)) * 100.0
                        usagePercent = min(100.0, max(0.0, pct))
                    }
                }
            }

            coreLoads.append(CoreCPULoad(coreIndex: coreIdx, counters: current, usagePercent: usagePercent))
        }


        self.previousCPUCounters = nextCounters

        return CPUHardwareSnapshot(
            model: model,
            architecture: arch,
            physicalCores: physicalCores,
            logicalCores: logicalCores,
            performanceCores: pCores,
            efficiencyCores: eCores,
            cores: coreLoads,
            unavailableReason: nil
        )
    }

    // MARK: - Memory Pressure Sampler

    private func sampleMemoryPressure() -> SystemMemoryPressure {
        let rawPressure = readSysctlInt("kern.memorystatus_vm_pressure_level")
        let memorystatusLevel = readSysctlInt("kern.memorystatus_level")

        let level: MemoryPressureLevel
        if let raw = rawPressure {
            level = MemoryPressureLevel.from(rawLevel: raw)
        } else {
            level = .unknown
        }

        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStat = vm_statistics64_data_t()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard kr == KERN_SUCCESS else {
            return SystemMemoryPressure(
                level: level,
                rawVMPressureLevel: rawPressure,
                memorystatusLevelPercentage: memorystatusLevel,
                pagesFree: 0,
                pagesActive: 0,
                pagesInactive: 0,
                pagesWired: 0,
                pagesPurgeable: 0,
                pagesCompressed: 0,
                pageins: 0,
                pageouts: 0,
                source: "kern.memorystatus",
                unavailableReason: "host_statistics64 failed with kern_return_t: \(kr)"
            )
        }

        return SystemMemoryPressure(
            level: level,
            rawVMPressureLevel: rawPressure,
            memorystatusLevelPercentage: memorystatusLevel,
            pagesFree: UInt64(max(0, vmStat.free_count)),
            pagesActive: UInt64(max(0, vmStat.active_count)),
            pagesInactive: UInt64(max(0, vmStat.inactive_count)),
            pagesWired: UInt64(max(0, vmStat.wire_count)),
            pagesPurgeable: UInt64(max(0, vmStat.purgeable_count)),
            pagesCompressed: UInt64(max(0, vmStat.compressor_page_count)),
            pageins: UInt64(max(0, vmStat.pageins)),
            pageouts: UInt64(max(0, vmStat.pageouts)),
            source: "kern.memorystatus + mach.host_statistics64",
            unavailableReason: rawPressure == nil || level == .unknown ? localized("内核未提供可识别的内存压力等级。") : nil
        )
    }

    // MARK: - GPU Sampler

    private func sampleGPU() -> [GPUSnapshot] {
        var gpus: [GPUSnapshot] = []
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IOAccelerator")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)

        let metalDevices = MTLCopyAllDevices()
        let fallbackModel = metalDevices.count == 1 ? metalDevices[0].name : localized("IOAccelerator 设备")

        if result == kIOReturnSuccess {
            var entry = IOIteratorNext(iterator)
            var gpuIndex = 0
            while entry != 0 && gpuIndex < 8 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = props?.takeRetainedValue() as? [String: Any] {

                    var modelName = fallbackModel
                    if let modelData = dict["model"] as? Data, let s = String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !s.isEmpty {
                        modelName = s
                    }

                    let coreCount = (dict["gpu-core-count"] as? Int).flatMap { (1...4096).contains($0) ? $0 : nil }
                    let ioClass = dict["IOClass"] as? String

                    var devUtil: Double? = nil
                    var rendUtil: Double? = nil
                    var tileUtil: Double? = nil
                    var inUseSysMem: UInt64? = nil
                    var allocPBSize: UInt64? = nil

                    if let perf = dict["PerformanceStatistics"] as? [String: Any] {
                        if let u = perf["Device Utilization %"] as? NSNumber {
                            devUtil = Self.validPercent(u.doubleValue)
                        }
                        if let u = perf["Renderer Utilization %"] as? NSNumber {
                            rendUtil = Self.validPercent(u.doubleValue)
                        }
                        if let u = perf["Tiler Utilization %"] as? NSNumber {
                            tileUtil = Self.validPercent(u.doubleValue)
                        }
                        if let m = perf["In use system memory"] as? NSNumber {
                            inUseSysMem = m.int64Value >= 0 ? m.uint64Value : nil
                        }
                        if let pb = perf["Allocated PB Size"] as? NSNumber {
                            allocPBSize = pb.int64Value >= 0 ? pb.uint64Value : nil
                        }
                    }

                    gpus.append(GPUSnapshot(
                        model: modelName,
                        coreCount: coreCount,
                        deviceUtilizationPercent: devUtil,
                        rendererUtilizationPercent: rendUtil,
                        tilerUtilizationPercent: tileUtil,
                        inUseSystemMemoryBytes: inUseSysMem,
                        allocatedPBSizeBytes: allocPBSize,
                        ioClass: ioClass,
                        unavailableReason: devUtil == nil ? localized("驱动未提供有效的 GPU 利用率。") : nil
                    ))
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
                gpuIndex += 1
            }
            if entry != 0 { IOObjectRelease(entry) }
            IOObjectRelease(iterator)
        }

        if gpus.isEmpty {
            // Fallback from Metal if no IOAccelerator service found
            for dev in metalDevices.prefix(4) {
                gpus.append(GPUSnapshot(
                    model: dev.name,
                    coreCount: nil,
                    deviceUtilizationPercent: nil,
                    rendererUtilizationPercent: nil,
                    tilerUtilizationPercent: nil,
                    inUseSystemMemoryBytes: nil,
                    allocatedPBSizeBytes: nil,
                    ioClass: nil,
                    unavailableReason: "IOAccelerator service not found in registry"
                ))
            }
        }

        return gpus
    }

    // MARK: - SMC Thermal & Fan Sampler (Strictly Read-Only, No Privileged Bypass)

    private func sampleSMCThermal() -> SMCThermalSnapshot {
        guard ProcessInfo.processInfo.systemUptime >= smcRetryAt else {
            return SMCThermalSnapshot(fanSpeedsRPM: [], temperaturesCelsius: [:], isAvailable: false, unavailableReason: smcError)
        }
        do {
            if smc == nil {
                let reader = try SMCReader()
                thermalKeys = try reader.keys().filter {
                    $0.hasPrefix("Tp") || $0.hasPrefix("Te") || $0.hasPrefix("Tg") || $0.hasPrefix("Tf") || ["TC0P", "TC0D", "TG0P", "TG0D"].contains($0)
                }.prefix(64).map { $0 }
                smc = reader
            }
            guard let smc else { throw NSError(domain: "AppleSMC", code: -1) }
            var fans: [Double] = []
            var fanCount: Int?
            if let count = try? smc.read("FNum"), count >= 0, count <= 8, count.rounded() == count {
                fanCount = Int(count)
                for index in 0..<Int(count) {
                    if let speed = try? smc.read("F\(index)Ac"), (0...20000).contains(speed) { fans.append(speed) }
                }
            }
            var temperatures: [String: Double] = [:]
            for key in thermalKeys {
                if let value = try? smc.read(key), value > 0, value <= 150 { temperatures[key] = value }
            }
            let reason = fans.isEmpty && temperatures.isEmpty ? localized("SMC 未提供可验证的温度或风扇读数。") : nil
            return SMCThermalSnapshot(fanSpeedsRPM: fans, temperaturesCelsius: temperatures, isAvailable: reason == nil, unavailableReason: reason, fanCount: fanCount)
        } catch {
            smc = nil; smcError = error.localizedDescription; smcRetryAt = ProcessInfo.processInfo.systemUptime + 30
            return SMCThermalSnapshot(fanSpeedsRPM: [], temperaturesCelsius: [:], isAvailable: false, unavailableReason: error.localizedDescription)
        }
    }

    // MARK: - Battery Sampler

    private func sampleBattery() -> BatterySnapshot {
        // First check AppleSmartBattery in IORegistry
        var batIter: io_iterator_t = 0
        var isInstalled = false
        var cycleCount: Int? = nil
        var currentCapacitymAh: Int? = nil
        var maxCapacitymAh: Int? = nil
        var voltageMilliVolts: Int? = nil
        var amperageMilliAmps: Int? = nil
        var isCharging: Bool? = nil
        var condition: String? = nil

        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &batIter) == kIOReturnSuccess {
            let bEntry = IOIteratorNext(batIter)
            if bEntry != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(bEntry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                   let dict = props?.takeRetainedValue() as? [String: Any] {

                    if let installed = dict["BatteryInstalled"] as? Bool {
                        isInstalled = installed
                    } else if let installedNum = dict["BatteryInstalled"] as? Int {
                        isInstalled = (installedNum != 0)
                    }

                    if isInstalled {
                        cycleCount = dict["CycleCount"] as? Int
                        currentCapacitymAh = dict["AppleRawCurrentCapacity"] as? Int
                        maxCapacitymAh = dict["AppleRawMaxCapacity"] as? Int
                        voltageMilliVolts = dict["Voltage"] as? Int
                        amperageMilliAmps = dict["Amperage"] as? Int
                        isCharging = dict["IsCharging"] as? Bool
                        if let cond = dict["BatteryHealth"] as? String ?? dict["Condition"] as? String {
                            condition = cond
                        }
                    }
                }
                IOObjectRelease(bEntry)
            }
            IOObjectRelease(batIter)
        }

        // Secondary check via IOPowerSources API
        var psPercent: Int? = nil
        var psPowerSourceState: String? = nil
        var psIsCharging: Bool? = nil
        var psIsACConnected: Bool? = nil

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           !list.isEmpty {
            for ps in list {
                if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] {
                    let type = desc[kIOPSTypeKey as String] as? String
                    if type == (kIOPSInternalBatteryType as String) || type == "InternalBattery" {
                        isInstalled = true
                        if let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
                           let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                            psPercent = Self.capacityPercent(current: cur, maximum: max)
                        }
                        if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                            psIsCharging = charging
                        }
                        if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                            psPowerSourceState = state
                            psIsACConnected = (state == (kIOPSACPowerValue as String))
                        }
                        if condition == nil, let cond = desc[kIOPSBatteryHealthKey as String] as? String {
                            condition = cond
                        }
                        break
                    }
                }
            }
        }

        guard isInstalled else {
            return BatterySnapshot(
                isInstalled: false,
                currentCapacityPercent: nil,
                isCharging: nil,
                isACConnected: psIsACConnected,
                powerSourceState: psPowerSourceState,
                condition: nil,
                cycleCount: nil,
                currentCapacitymAh: nil,
                maxCapacitymAh: nil,
                voltageMilliVolts: nil,
                amperageMilliAmps: nil,
                watts: nil,
                unavailableReason: localized("系统未检测到内置电池；不能仅凭读取失败推断硬件不适用。")
            )
        }

        // Calculate percentage from mAh if IOPowerSources percentage not available
        let percent: Int?
        if let p = psPercent {
            percent = p
        } else if let cur = currentCapacitymAh, let max = maxCapacitymAh, max > 0 {
            percent = Self.capacityPercent(current: cur, maximum: max)
        } else {
            percent = nil
        }

        // Calculate power in Watts = (abs(Amperage) * Voltage) / 1,000,000.0
        var watts: Double? = nil
        if let v = voltageMilliVolts, let a = amperageMilliAmps, v > 0, v <= 100000, abs(Double(a)) <= 100000 {
            let mW = abs(Double(a)) * Double(v)
            watts = mW / 1_000_000.0
        }

        return BatterySnapshot(
            isInstalled: true,
            currentCapacityPercent: percent.flatMap { (0...100).contains($0) ? $0 : nil },
            isCharging: psIsCharging ?? isCharging,
            isACConnected: psIsACConnected,
            powerSourceState: psPowerSourceState,
            condition: condition,
            cycleCount: cycleCount,
            currentCapacitymAh: currentCapacitymAh,
            maxCapacitymAh: maxCapacitymAh,
            voltageMilliVolts: voltageMilliVolts,
            amperageMilliAmps: amperageMilliAmps,
            watts: watts,
            unavailableReason: nil
        )
    }

    // MARK: - Bluetooth Accessory Sampler

    private func sampleBluetoothAccessories() -> [BluetoothAccessorySnapshot] {
        var accessories: [String: BluetoothAccessorySnapshot] = [:]
        let classesToScan = [
            "AppleDeviceManagementHIDEventService",
            "IOAppleBluetoothDevice",
            "AppleBluetoothHIDDevice",
            "BNBMouseDevice",
            "BNBTrackpadDevice"
        ]

        var totalEntriesScanned = 0

        for serviceClass in classesToScan {
            guard totalEntriesScanned < 32 else { break }
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iter) == kIOReturnSuccess {
                var entry = IOIteratorNext(iter)
                while entry != 0 && totalEntriesScanned < 32 {
                    totalEntriesScanned += 1
                    var props: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                       let dict = props?.takeRetainedValue() as? [String: Any] {

                        let name = dict["Product"] as? String
                            ?? dict["DeviceName"] as? String
                            ?? dict["Name"] as? String
                            ?? dict["BTName"] as? String

                        let address = dict["DeviceAddress"] as? String
                            ?? dict["SerialNumber"] as? String
                            ?? dict["Address"] as? String

                        let bat = dict["BatteryPercent"] as? Int
                            ?? (dict["BatteryStatus"] as? [String: Any])?["Percent"] as? Int
                        let caseBat = dict["BatteryPercentCase"] as? Int
                        let leftBat = dict["BatteryPercentLeft"] as? Int
                        let rightBat = dict["BatteryPercentRight"] as? Int
                        let isCharging = dict["BatteryCharging"] as? Bool ?? dict["IsCharging"] as? Bool

                        if let name = name, (bat != nil || caseBat != nil || leftBat != nil || rightBat != nil) {
                            var registryID: UInt64 = 0; _ = IORegistryEntryGetRegistryEntryID(entry, &registryID)
                            let dedupId = address.flatMap { $0.isEmpty ? nil : $0.lowercased().replacingOccurrences(of: "-", with: ":") } ?? "registry:\(registryID)"
                            if accessories[dedupId] == nil {
                                accessories[dedupId] = BluetoothAccessorySnapshot(
                                    id: dedupId,
                                    name: name,
                                    batteryPercent: bat.flatMap { (0...100).contains($0) ? $0 : nil },
                                    caseBatteryPercent: caseBat.flatMap { (0...100).contains($0) ? $0 : nil },
                                    leftBatteryPercent: leftBat.flatMap { (0...100).contains($0) ? $0 : nil },
                                    rightBatteryPercent: rightBat.flatMap { (0...100).contains($0) ? $0 : nil },
                                    isCharging: isCharging,
                                    deviceAddress: address,
                                    source: serviceClass
                                )
                            }
                        }
                    }
                    IOObjectRelease(entry)
                    entry = IOIteratorNext(iter)
                }
                if entry != 0 { IOObjectRelease(entry) }
                IOObjectRelease(iter)
            }
        }

        return Array(accessories.values.sorted { $0.id < $1.id }.prefix(32))
    }

    // MARK: - Network Interfaces Sampler

    private func sampleNetworkInterfaces() -> [NetworkInterfaceDetail] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(ifaddrPtr) }

        var interfaceMap: [String: (
            ipv4: [String],
            masks: [String],
            ipv6: [String],
            isUp: Bool,
            isLoopback: Bool,
            isPointToPoint: Bool,
            isVPN: Bool,
            flags: UInt32
        )] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        var scanCount = 0

        while let cur = ptr, scanCount < 128 {
            scanCount += 1
            let name = String(cString: cur.pointee.ifa_name)
            let flags = cur.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            let isP2P = (flags & UInt32(IFF_POINTOPOINT)) != 0
            let isVPN = isP2P || name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") || name.hasPrefix("tap") || name.hasPrefix("tun")

            var record = interfaceMap[name] ?? (
                ipv4: [],
                masks: [],
                ipv6: [],
                isUp: isUp,
                isLoopback: isLoopback,
                isPointToPoint: isP2P,
                isVPN: isVPN,
                flags: flags
            )

            if let addr = cur.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if !record.ipv4.contains(ip) {
                            record.ipv4.append(ip)
                        }
                    }
                    if let netmask = cur.pointee.ifa_netmask {
                        var maskHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(netmask, socklen_t(netmask.pointee.sa_len), &maskHost, socklen_t(maskHost.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let mask = String(decoding: maskHost.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            record.masks.append(mask)
                        }
                    }
                } else if family == UInt8(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if !record.ipv6.contains(ip) {
                            record.ipv6.append(ip)
                        }
                    }
                }
            }

            interfaceMap[name] = record
            ptr = cur.pointee.ifa_next
        }

        return interfaceMap.map { name, val in
            NetworkInterfaceDetail(
                name: name,
                ipv4Addresses: val.ipv4,
                ipv4Netmasks: val.masks,
                ipv6Addresses: val.ipv6,
                isUp: val.isUp,
                isLoopback: val.isLoopback,
                isPointToPoint: val.isPointToPoint,
                isVPN: val.isVPN,
                flags: val.flags
            )
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Sysctl Helpers

    private func readSysctlString(_ name: String) -> String? {
        var size: Int = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0, size <= 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readSysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return Int(value)
    }

}
