import AppKit
import Darwin
import SwiftUI

struct WindowProbe: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onAttach = onAttach
    }

    final class Probe: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { [weak self] in self?.onAttach?(window) } }
        }
    }
}

@MainActor
final class ViewerDiagnostics {
    private let clock = ContinuousClock()
    private var startTime: ContinuousClock.Instant?
    private var count: Int?
    private var enumerationTime: Duration?
    private var firstDrawTime: Duration?
    private var baseline: UInt64?
    private var firstMemory: UInt64?

    func reset() {
        startTime = nil
        count = nil
        enumerationTime = nil
        firstDrawTime = nil
        baseline = nil
        firstMemory = nil
    }

    func start() {
        reset()
        baseline = snapshot()?.footprint
        startTime = clock.now
    }

    func enumerated(_ count: Int) {
        guard let startTime else { return }
        self.count = count
        enumerationTime = startTime.duration(to: clock.now)
    }

    func firstDraw() {
        guard let startTime, count != nil, firstDrawTime == nil else { return }
        firstDrawTime = startTime.duration(to: clock.now)
        firstMemory = snapshot()?.footprint
    }

    func report() -> String {
        var lines: [String] = []
        if let count { lines.append("\(count.formatted()) images in the last opened folder") }
        else { lines.append("Open a folder to measure first draw.") }
        if let enumerationTime { lines.append("Folder listed in \(milliseconds(enumerationTime))") }
        if let firstDrawTime { lines.append("First canvas draw in \(milliseconds(firstDrawTime))") }
        if let baseline { lines.append("Before folder open \(mib(baseline))") }
        if let firstMemory { lines.append("At first draw \(mib(firstMemory))") }
        if let latest = snapshot() {
            lines.append("Current footprint \(mib(latest.footprint))")
            lines.append("Process lifetime peak \(mib(latest.peak))")
        }
        return lines.joined(separator: "\n")
    }

    private func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        let ms = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        return String(format: "%.1f ms", ms)
    }

    private func mib(_ bytes: UInt64) -> String {
        String(format: "%.1f MiB", Double(bytes) / 1_048_576)
    }

    private func snapshot() -> (footprint: UInt64, peak: UInt64)? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return (info.phys_footprint, UInt64(max(info.ledger_phys_footprint_peak, 0)))
    }
}
