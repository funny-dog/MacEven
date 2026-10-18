import MacEvenCore
import Foundation
import Darwin
import IOKit
import SystemConfiguration

@main
struct HardwareChecks {
    static func main() {
        print("=== [HardwareChecks] Starting Native Hardware Verification ===")

        precondition(SystemHardware.capacityPercent(current: .max, maximum: .max) == 100)
        precondition(SystemHardware.capacityPercent(current: .max, maximum: 1) == nil)
        precondition(SystemHardware.capacityPercent(current: -1, maximum: 100) == nil)
        precondition(SystemHardware.capacityPercent(current: 1, maximum: 0) == nil)
        precondition(SystemHardware.validPercent(.nan) == nil && SystemHardware.validPercent(101) == nil)
        let sampler = SystemHardware()
        sampler.resetBaselines()

        // First sample (establishes CPU tick baselines)
        print("-> Taking baseline sample 1...")
        let snap1 = sampler.sample()

        print("  Sample 1 duration: \(String(format: "%.4f", snap1.sampleDurationSeconds))s")
        assert(snap1.sampleDurationSeconds >= 0 && snap1.sampleDurationSeconds < 5.0, "Sample duration should be reasonable")

        // Brief sleep to allow CPU ticks to accumulate
        Thread.sleep(forTimeInterval: 0.2)

        // Second sample (calculates per-core usage delta)
        print("-> Taking delta sample 2...")
        let snap2 = sampler.sample()
        print("  Sample 2 duration: \(String(format: "%.4f", snap2.sampleDurationSeconds))s")

        // 1. CPU Verification
        print("\n--- 1. CPU Hardware Check ---")
        print("  Model: \(snap2.cpu.model)")
        print("  Architecture: \(snap2.cpu.architecture)")
        print("  Physical Cores: \(snap2.cpu.physicalCores)")
        print("  Logical Cores: \(snap2.cpu.logicalCores)")
        if let p = snap2.cpu.performanceCores { print("  P-Cores: \(p)") }
        if let e = snap2.cpu.efficiencyCores { print("  E-Cores: \(e)") }
        print("  Active per-core load count: \(snap2.cpu.cores.count)")

        assert(!snap2.cpu.model.isEmpty, "CPU model should not be empty")
        assert(!snap2.cpu.architecture.isEmpty, "CPU architecture should not be empty")
        assert(snap2.cpu.physicalCores > 0, "Physical cores must be > 0")
        assert(snap2.cpu.logicalCores >= snap2.cpu.physicalCores, "Logical cores must be >= physical cores")
        assert(snap2.cpu.cores.count == snap2.cpu.logicalCores, "Per-core load count should match logical cores")

        for core in snap2.cpu.cores {
            assert(core.counters.totalTicks > 0, "Total ticks for core \(core.coreIndex) must be > 0")
            if let pct = core.usagePercent {
                print("    Core \(core.coreIndex) usage: \(String(format: "%.1f", pct))% (user=\(core.counters.user), sys=\(core.counters.system), idle=\(core.counters.idle))")
                assert(pct >= 0.0 && pct <= 100.0, "Core usage percentage must be within [0.0, 100.0]")
            } else {
                print("    Core \(core.coreIndex) usage: nil")
            }
        }

        // 2. Memory Pressure Verification (System kernel source, not used/total)
        print("\n--- 2. System Memory Pressure Check ---")
        print("  Pressure Level: \(snap2.memoryPressure.level.rawValue)")
        print("  Raw VM Pressure Level: \(snap2.memoryPressure.rawVMPressureLevel.map(String.init) ?? "nil")")
        print("  Memorystatus Level %: \(snap2.memoryPressure.memorystatusLevelPercentage.map(String.init) ?? "nil")")
        print("  Pages Free: \(snap2.memoryPressure.pagesFree)")
        print("  Pages Active: \(snap2.memoryPressure.pagesActive)")
        print("  Pages Wired: \(snap2.memoryPressure.pagesWired)")
        print("  Pages Compressed: \(snap2.memoryPressure.pagesCompressed)")
        print("  Source: \(snap2.memoryPressure.source)")

        assert(snap2.memoryPressure.source.contains("memorystatus"), "Source must be memorystatus")
        assert(snap2.memoryPressure.pagesFree >= 0, "Pages free must be >= 0")
        assert(snap2.memoryPressure.pagesActive > 0, "Pages active must be > 0")

        // 3. GPU Verification
        print("\n--- 3. GPU Check ---")
        print("  GPU count: \(snap2.gpu.count)")
        assert(!snap2.gpu.isEmpty, "Should detect at least 1 GPU")
        for (i, gpu) in snap2.gpu.enumerated() {
            print("  GPU [\(i)]: \(gpu.model), Cores: \(gpu.coreCount.map(String.init) ?? "unknown"), IOClass: \(gpu.ioClass ?? "unknown")")
            if let devUtil = gpu.deviceUtilizationPercent {
                print("    Device Utilization: \(String(format: "%.1f", devUtil))%")
                assert(devUtil >= 0.0 && devUtil <= 100.0, "GPU utilization must be within [0.0, 100.0]")
            }
            if let rendUtil = gpu.rendererUtilizationPercent {
                print("    Renderer Utilization: \(String(format: "%.1f", rendUtil))%")
            }
            if let mem = gpu.inUseSystemMemoryBytes {
                print("    In-use GPU memory: \(mem / 1024 / 1024) MB")
            }
            if let reason = gpu.unavailableReason {
                print("    Unavailable Reason: \(reason)")
            }
        }

        // 4. Thermal & SMC Verification
        print("\n--- 4. Thermal & SMC Check ---")
        print("  ProcessInfo Thermal State: \(snap2.thermalState.rawValue)")
        print("  AppleSMC Available: \(snap2.smcThermal.isAvailable)")
        if let reason = snap2.smcThermal.unavailableReason {
            print("  AppleSMC Unavailable Reason: \(reason)")
            assert(!reason.isEmpty, "Unavailable reason must be specified when SMC is unavailable")
        }
        if snap2.smcThermal.isAvailable {
            print("  Fan speeds: \(snap2.smcThermal.fanSpeedsRPM)")
        }

        // 5. Battery Verification
        print("\n--- 5. Battery Check ---")
        print("  Installed: \(snap2.battery.isInstalled)")
        if snap2.battery.isInstalled {
            print("  Capacity %: \(snap2.battery.currentCapacityPercent.map(String.init) ?? "nil")%")
            print("  Charging: \(snap2.battery.isCharging.map(String.init) ?? "nil")")
            print("  Cycle Count: \(snap2.battery.cycleCount.map(String.init) ?? "nil")")
            if let w = snap2.battery.watts { print("  Power: \(String(format: "%.2f", w)) W") }
        } else {
            print("  Unavailable Reason: \(snap2.battery.unavailableReason ?? "None")")
            assert(snap2.battery.unavailableReason != nil, "Desktop/no battery machine must have unavailableReason")
        }

        // 6. Bluetooth Accessories Verification
        print("\n--- 6. Bluetooth Accessories Check ---")
        print("  Accessories found: \(snap2.bluetoothAccessories.count)")
        for acc in snap2.bluetoothAccessories {
            print("  Accessory: \(acc.name) (id: \(acc.id), battery: \(acc.batteryPercent.map(String.init) ?? "nil")%, src: \(acc.source))")
        }
        print("  iOS Bluetooth Unavailable Reason: \(snap2.bluetoothiOSUnavailableReason)")
        assert(!snap2.bluetoothiOSUnavailableReason.isEmpty, "iOS Bluetooth unavailable reason must be stated")

        // 7. Network Interfaces Verification
        print("\n--- 7. Network Interfaces Check ---")
        print("  Total interfaces: \(snap2.networkInterfaces.count)")
        assert(!snap2.networkInterfaces.isEmpty, "Must detect at least 1 network interface")
        var foundLoopback = false
        var foundUp = false
        for iface in snap2.networkInterfaces {
            if iface.isLoopback { foundLoopback = true }
            if iface.isUp { foundUp = true }
            print("  \(iface.name): Up=\(iface.isUp), Loopback=\(iface.isLoopback), P2P=\(iface.isPointToPoint), VPN=\(iface.isVPN)")
            if !iface.ipv4Addresses.isEmpty {
                print("    IPv4: \(iface.ipv4Addresses.joined(separator: ", ")) (Masks: \(iface.ipv4Netmasks.joined(separator: ", ")))")
            }
            if !iface.ipv6Addresses.isEmpty {
                print("    IPv6: \(iface.ipv6Addresses.joined(separator: ", "))")
            }
        }
        assert(foundLoopback, "Loopback interface (lo0) must be detected")
        assert(foundUp, "At least one UP interface must be detected")

        print("\n=== [HardwareChecks] All Native Hardware Checks Passed Successfully! ===")
    }
}
