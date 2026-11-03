import SwiftUI
import IngestCore

struct QueueView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Transfer Queue", systemImage: "list.number").font(.title2.bold())
                    Text("Jobs are saved across restarts. Resume rechecks saved data. Estimates include source reads and destination I/O. Finalization and shared-device stalls can extend them.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { model.showingQueue = false }.keyboardShortcut(.defaultAction)
            }
            if model.jobs.isEmpty {
                ContentUnavailableView("No queued jobs", systemImage: "tray", description: Text("Choose sources and destinations, then Start Copy or Add to Queue. Review Copy is optional."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.jobs) { job in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: icon(job.status)).foregroundStyle(job.status == .failed ? Color.red : job.status == .completed ? Color.green : Color.purple)
                                    Text(job.plan.projectName).font(.headline)
                                    Spacer()
                                    Text(job.status.rawValue.capitalized).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 4).background(.quaternary, in: Capsule())
                                }
                                Text("\(job.plan.sources.count) sources → \(job.plan.destinations.count) destinations · \(job.plan.files.count) files · \(job.finishedFiles) processed").font(.caption).foregroundStyle(.secondary)
                                Text(job.plan.folderName).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                if job.id == model.activeJobID {
                                    ProgressView(value: model.fraction)
                                    let pending = (job.destinationProgress ?? []).filter { $0.phase != "Verified" && $0.phase != "Working copy verified · backups pending" }
                                    if let cascadeEstimate = cascadeEstimate(job) {
                                        Text("Cascading estimate: " + eta(cascadeEstimate, phase: "Running")).font(.caption).help("Pending backups are estimated using the working destination rate until their own rate is measured.")
                                    } else if !pending.isEmpty, pending.allSatisfy({ $0.estimatedSecondsRemaining != nil && Date().timeIntervalSince($0.updatedAt ?? .distantPast) < 10 }), let longest = pending.compactMap(\.estimatedSecondsRemaining).max() {
                                        Text("Estimated remaining: " + eta(longest, phase: "Running")).font(.caption)
                                    } else { Text("Estimating job time remaining…").font(.caption).foregroundStyle(.secondary) }
                                    Text(model.phase + (model.detail.isEmpty ? "" : " · " + model.detail)).font(.caption).lineLimit(2)
                                }
                                if job.plan.settings.cascade { Text("Cascading · first destination is the working copy").font(.caption).foregroundStyle(.secondary) }
                                ForEach(job.destinationProgress ?? []) { destination in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(destination.root.lastPathComponent).font(.caption.bold())
                                            Spacer()
                                            Text(destination.phase).font(.caption).foregroundStyle(destination.error == nil ? Color.secondary : Color.red)
                                        }
                                        Text(destination.root.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(destination.root.path)
                                        Text("Copy").font(.caption2)
                                        ProgressView(value: min(1, Double(destination.copiedBytes) / Double(max(1, destination.totalBytes))))
                                        Text("Verification").font(.caption2)
                                        ProgressView(value: min(1, Double(destination.verifiedBytes) / Double(max(1, destination.totalBytes))))
                                        Text("Written \(ByteCountFormatter.string(fromByteCount: destination.copiedBytes, countStyle: .file)) · Read back \(ByteCountFormatter.string(fromByteCount: destination.verifiedBytes, countStyle: .file)) · Avg I/O \(String(format: "%.1f", destination.bytesPerSecond / 1_000_000)) MB/s").font(.caption2).monospacedDigit()
                                        Text(eta(job.status == .running && Date().timeIntervalSince(destination.updatedAt ?? .distantPast) < 10 ? destination.estimatedSecondsRemaining : nil, phase: job.status == .paused ? "Paused" : destination.phase)).font(.caption).foregroundStyle(.secondary)
                                        Text("Copy \(String(format: "%.1f", (job.status == .running && Date().timeIntervalSince(destination.updatedAt ?? .distantPast) < 10 ? destination.copySpeed ?? 0 : 0) / 1_000_000)) MB/s · Verify \(String(format: "%.1f", (job.status == .running && Date().timeIntervalSince(destination.updatedAt ?? .distantPast) < 10 ? destination.verificationSpeed ?? 0 : 0) / 1_000_000)) MB/s · Elapsed \(Int(destination.elapsedSeconds ?? 0)) s").font(.caption2).monospacedDigit()
                                        Text(destination.storage).font(.caption2).foregroundStyle(.secondary)
                                        Button("Show Destination") { NSWorkspace.shared.activateFileViewerSelecting([destination.root]) }.font(.caption)
                                        if let error = destination.error { Text(error).font(.caption2).foregroundStyle(.red).textSelection(.enabled) }
                                    }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                }
                                if let error = job.lastError { Text(error).font(.caption).foregroundStyle(job.status == .paused ? Color.secondary : Color.red).textSelection(.enabled) }
                                HStack(spacing: 12) {
                                    if job.status == .paused || job.status == .failed {
                                        Button("Resume") { model.resumeJob(job.id) }.disabled(model.hasActiveWork || model.safety == nil)
                                    }
                                    if job.status == .failed { Button("Retry Report Export") { model.retryJobReports(job) } }
                                    if !job.reports.isEmpty { Button("Report") { model.showJobReport(job) }.disabled(model.hasActiveWork) }
                                    Spacer()
                                    Button { model.moveJob(job.id, offset: -1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move job earlier").help("Move job earlier")
                                    Button { model.moveJob(job.id, offset: 1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move job later").help("Move job later")
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.plan.destinations.first!.root]) }
                                    Button("Forget") { model.forgetJob(job.id) }.help("Remove from queue only. Copied and partial files are retained.")
                                }.disabled(model.hasActiveWork)
                            }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("Show Queue Storage", action: model.showQueueFolder)
                Text("One job runs at a time. Healthy destinations finish before a failed job stops the queue.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.queueRunning { Button("Pause Queue", action: model.stop) }
                else { Button("Start Queue", action: model.startQueue).buttonStyle(.borderedProminent).disabled(model.busy || model.safety == nil || !model.jobs.contains(where: { $0.status == .queued })) }
            }
        }.padding(24).frame(width: 920, height: 650)
        }
    }
    private func cascadeEstimate(_ job: TransferJob) -> Double? {
        guard job.plan.settings.cascade, let values = job.destinationProgress, let primary = values.first,
              values.dropFirst().contains(where: { $0.phase == "Waiting" }),
              Date().timeIntervalSince(primary.updatedAt ?? .distantPast) < 10,
              let remaining = primary.estimatedSecondsRemaining, let elapsed = primary.elapsedSeconds, elapsed >= 3 else { return nil }
        let work = primary.copiedBytes + primary.verifiedBytes + (primary.sourceReadBytes ?? 0) + (primary.publicationBytes ?? 0)
        let rate = Double(work) / elapsed
        guard rate > 0 else { return nil }
        let future = values.dropFirst().reduce(0.0) { total, value in
            let compatible = (try? value.root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming) == false
            return total + Double(value.totalBytes) * (compatible ? 7 : 4) / rate
        }
        return remaining + future
    }
    private func eta(_ seconds: Double?, phase: String) -> String {
        if phase.hasPrefix("Verified") { return "Complete" }
        if phase == "Working copy verified · backups pending" { return "Working copy complete · backups continuing" }
        if phase == "Finalizing" || phase.hasPrefix("Publishing") || phase == "Writing interoperable manifests" { return "Finalizing verified copy…" }
        if ["Failed", "Paused", "Incomplete"].contains(phase) { return "Time remaining unavailable" }
        guard let seconds, seconds.isFinite else { return "Estimating time remaining…" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        return minutes >= 60 ? "About \(minutes / 60) hr \(minutes % 60) min remaining" : seconds < 60 ? "Less than a minute remaining" : "About \(minutes) min remaining"
    }
    private func icon(_ status: TransferStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        case .completed: return "checkmark.seal.fill"
        }
    }
}
