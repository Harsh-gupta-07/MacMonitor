import SwiftUI
import Foundation
import Darwin

// MARK: - System Monitor
@MainActor
class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var ramUsage: Double = 0.0
    @Published var ramUsedGB: Double = 0.0
    @Published var ramTotalGB: Double = 0.0
    @Published var swapUsedGB: Double = 0.0
    @Published var downloadSpeed: Double = 0.0  // MB/s
    @Published var uploadSpeed: Double = 0.0    // MB/s
    
    private var timer: Timer?
    
    // Store previous CPU ticks for delta calculation
    private var previousTotalTicks: Double = 0
    private var previousUsedTicks: Double = 0

    // Store previous network byte counts for delta calculation
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    
    init() {
        updateUsage()
        startMonitoring()
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateUsage()
            }
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateUsage() {
        cpuUsage = getCPUUsage()
        (ramUsage, ramUsedGB, swapUsedGB, ramTotalGB) = getRAMUsage()
        (downloadSpeed, uploadSpeed) = getNetworkSpeed()
    }
    
    private func getCPUUsage() -> Double {
        var numProcessors: mach_msg_type_number_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0
        
        let hostPort = mach_host_self()
        let result = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &numProcessors,
            &processorInfo,
            &processorInfoCount
        )
        mach_port_deallocate(mach_task_self_, hostPort)
        
        guard result == KERN_SUCCESS, let info = processorInfo else { return 0.0 }
        
        var totalUser: Double = 0
        var totalSystem: Double = 0
        var totalIdle: Double = 0
        var totalNice: Double = 0
        
        for i in 0..<Int(numProcessors) {
            let base = i * Int(CPU_STATE_MAX)
            let user   = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let idle   = Double(info[base + Int(CPU_STATE_IDLE)])
            let nice   = Double(info[base + Int(CPU_STATE_NICE)])
            
            totalUser += user
            totalSystem += system
            totalIdle += idle
            totalNice += nice
        }
        
        let currentTotalTicks = totalUser + totalSystem + totalIdle + totalNice
        let currentUsedTicks = totalUser + totalSystem + totalNice
        
        // Calculate delta from previous sample for current usage
        let deltaTotalTicks = currentTotalTicks - previousTotalTicks
        let deltaUsedTicks = currentUsedTicks - previousUsedTicks
        
        let isFirstUpdate = previousTotalTicks == 0
        
        // Store current values for next delta calculation
        previousTotalTicks = currentTotalTicks
        previousUsedTicks = currentUsedTicks
        
        // Deallocate with correct size
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: info),
            vm_size_t(Int(processorInfoCount) * MemoryLayout<integer_t>.stride)
        )
        
        // On first sample there's no previous data, return 0
        guard !isFirstUpdate, deltaTotalTicks > 0 else { return 0.0 }
        
        return (deltaUsedTicks / deltaTotalTicks) * 100.0
    }
    
    private func getRAMUsage() -> (percentage: Double, physicalUsedGB: Double, swapUsedGB: Double, totalGB: Double) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(
                    hostPort,
                    HOST_VM_INFO64,
                    $0,
                    &count
                )
            }
        }
        mach_port_deallocate(mach_task_self_, hostPort)

        guard result == KERN_SUCCESS else { return (0.0, 0.0, 0.0, 0.0) }

        // Dynamically read physical RAM via sysctl (avoids hardcoded value)
        var physicalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &physicalMemory, &size, nil, 0)
        let totalMemory = Double(physicalMemory)
        
        guard totalMemory > 0 else { return (0.0, 0.0, 0.0, 0.0) }

        let pageSize = Double(vm_kernel_page_size)

        // Activity Monitor "Memory Used" = App Memory + Wired Memory + Compressed
        let appMemory = Double(stats.active_count) +
                        max(0, Double(stats.inactive_count) - Double(stats.purgeable_count))
        let physicalUsedMemory = (
            appMemory +
            Double(stats.wire_count) +
            Double(stats.compressor_page_count)
        ) * pageSize

        // Fetch swap usage via sysctl
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0)
        let swapUsed = Double(swapUsage.xsu_used)

        // Numerator includes swap; denominator stays as physical RAM
        let usedMemory = physicalUsedMemory + swapUsed

        let percentage = (usedMemory / totalMemory) * 100.0
        let physicalUsedGB = physicalUsedMemory / 1_073_741_824
        let swapUsedGB = swapUsed / 1_073_741_824
        let totalGB = totalMemory / 1_073_741_824

        return (percentage, physicalUsedGB, swapUsedGB, totalGB)
    }
    
    // MARK: - Network Speed
    private func getNetworkSpeed() -> (download: Double, upload: Double) {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let firstAddr = ifaddrsPtr else {
            return (0, 0)
        }
        defer { freeifaddrs(ifaddrsPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = cursor {
            let flags = Int32(addr.pointee.ifa_flags)
            // Skip loopback and interfaces that are not up
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isUp = (flags & IFF_UP) != 0

            if isUp && !isLoopback,
               let data = addr.pointee.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self)
                bytesIn  += UInt64(networkData.pointee.ifi_ibytes)
                bytesOut += UInt64(networkData.pointee.ifi_obytes)
            }
            cursor = addr.pointee.ifa_next
        }

        let isFirstSample = previousBytesIn == 0 && previousBytesOut == 0
        let prevIn  = previousBytesIn
        let prevOut = previousBytesOut
        previousBytesIn  = bytesIn
        previousBytesOut = bytesOut

        guard !isFirstSample else { return (0, 0) }

        // Timer interval is 2 seconds; convert bytes/2s → MB/s
        let interval: Double = 2.0
        let deltaIn  = bytesIn  >= prevIn  ? Double(bytesIn  - prevIn)  : 0
        let deltaOut = bytesOut >= prevOut ? Double(bytesOut - prevOut) : 0
        let dlMBps = (deltaIn  / interval) / 1_048_576
        let ulMBps = (deltaOut / interval) / 1_048_576
        return (dlMBps, ulMBps)
    }

    deinit {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Usage Bar Component
struct UsageBar: View {
    let label: String
    let percentage: Double
    let color: Color
    let usedGB: Double?
    let swapGB: Double?
    let totalGB: Double?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(.caption, design: .default))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let used = usedGB, let total = totalGB {
                    if let swap = swapGB, swap > 0.05 {
                        Text(String(format: "%.1f + %.1f GB / %.1f GB", used, swap, total))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text(String(format: "%.1f GB / %.1f GB", used, total))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(String(format: "%.1f%%", percentage))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * min(max(percentage / 100.0, 0), 1))
                }
            }
            .frame(height: 8)
        }
        .frame(height: 40)
    }
}

// MARK: - Network Speed Row
struct NetworkSpeedRow: View {
    let download: Double  // MB/s
    let upload: Double    // MB/s

    /// Format a speed value with appropriate unit (KB/s or MB/s)
    private func format(_ mbps: Double) -> String {
        if mbps < 1.0 {
            return String(format: "%.0f KB/s", mbps * 1024)
        } else {
            return String(format: "%.1f MB/s", mbps)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network")
                .font(.system(.caption, design: .default))
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                // Download
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.cyan)
                        .imageScale(.small)
                    Text(format(download))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Upload
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.indigo)
                        .imageScale(.small)
                    Text(format(upload))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 40)
    }
}

// MARK: - Main Widget View
struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor
    
    var cpuColor: Color {
        if monitor.cpuUsage > 80 {
            return .red
        } else if monitor.cpuUsage > 50 {
            return .orange
        } else {
            return .green
        }
    }
    
    var ramColor: Color {
        if monitor.ramUsage > 80 {
            return .red
        } else if monitor.ramUsage > 50 {
            return .orange
        } else {
            return .green
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("System Monitor")
                    .font(.system(.headline, design: .default))
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Quit")
            }
            
            Divider()
            
            // CPU Usage
            UsageBar(
                label: "CPU",
                percentage: monitor.cpuUsage,
                color: cpuColor,
                usedGB: nil,
                swapGB: nil,
                totalGB: nil
            )
            
            // RAM Usage
            UsageBar(
                label: "RAM",
                percentage: monitor.ramUsage,
                color: ramColor,
                usedGB: monitor.ramUsedGB,
                swapGB: monitor.swapUsedGB,
                totalGB: monitor.ramTotalGB
            )

            // Network Speed
            NetworkSpeedRow(
                download: monitor.downloadSpeed,
                upload: monitor.uploadSpeed
            )
            
            // Stats Summary
            HStack(spacing: 16) {
                VStack(alignment: .center, spacing: 4) {
                    Text(String(format: "%.0f%%", monitor.cpuUsage))
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                    
                    Text("CPU")
                        .font(.system(.caption2, design: .default))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                Divider()
                    .frame(height: 40)
                
                VStack(alignment: .center, spacing: 4) {
                    Text(String(format: "%.0f%%", monitor.ramUsage))
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                    
                    Text("RAM")
                        .font(.system(.caption2, design: .default))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

// // MARK: - App Entry Point
// @main
// struct MenuBarWidgetApp: App {
//     @StateObject private var monitor = SystemMonitor()

//     var body: some Scene {
//         MenuBarExtra {
//             ContentView(monitor: monitor)
//         } label: {
//             Label(
//                 String(format: "%.0f%%", monitor.ramUsage),
//                 systemImage: "memorychip"
//                 )
//                 .labelStyle(.titleAndIcon)
//                 .font(.system(size: 11, weight: .semibold, design: .monospaced))
//         }
//         .menuBarExtraStyle(.window)
//     }
// }

@main
struct MenuBarWidgetApp: App {
    @StateObject private var monitor = SystemMonitor()

    /// Format a speed value with appropriate unit (KB/s or MB/s) — compact for menu bar
    private func formatSpeed(_ mbps: Double) -> String {
        if mbps < 1.0 {
            return String(format: "%.0fK", mbps * 1024)
        } else {
            return String(format: "%.1fM", mbps)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            Text(
                String(format: "%.0f%% %.0f%%  ↓%@ ↑%@",
                    monitor.cpuUsage,
                    monitor.ramUsage,
                    formatSpeed(monitor.downloadSpeed),
                    formatSpeed(monitor.uploadSpeed)
                )
            )
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}