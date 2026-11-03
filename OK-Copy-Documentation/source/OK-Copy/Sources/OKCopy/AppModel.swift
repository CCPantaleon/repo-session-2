import SwiftUI
import AppKit
import QuickLookThumbnailing
import IngestCore
import WebKit
import UserNotifications

struct MountedCard: Identifiable {
    let url: URL
    let name: String
    let hasDCIM: Bool
    var id: String { url.path }
}

@MainActor final class AppModel: ObservableObject {
    @Published var notificationsEnabled = false
    @Published var cards: [MountedCard] = []
    @Published var sources: [SourceSelection] = []
    @Published var snapshot: CardSnapshot?
    @Published var selectedSourceID: UUID?
    @Published var selectedFileID: String?
    @Published var thumbnail: NSImage?
    @Published var projectName = ""
    @Published var destinations: [URL] = []
    @Published var copyLayout: CopyLayout = .organized
    @Published var reportStorage: ReportStorage = .app
    @Published var reportFolder: URL?
    @Published var cascade = false
    @Published var concurrentSources = 2
    @Published var exportManifests = false
    @Published var incremental = true
    @Published var dryRun = true
    @Published var busy = false { didSet { updateActivity() } }
    @Published var queueRunning = false { didSet { updateActivity() } }
    @Published var showingQueue = false
    @Published var jobs: [TransferJob] = []
    @Published var activeJobID: UUID?
    @Published var phase = "Choose sources to begin"
    @Published var detail = "Choose folders on your Mac, an external drive, or a camera card."
    @Published var fraction = 0.0
    @Published var completedFiles = 0
    @Published var errorMessage: String?
    @Published var resultMessage: String?
    @Published var safety: SafetyCheckResult?
    @Published var safetyRunning = false
    @Published var reportURLs: [URL] = []
    @Published var reportHTML: String?
    @Published var showingReport = false { didSet { if showingReport { presentReportWindow() } } }
    private var reportWindow: NSWindow?
    @Published var showingHistory = false
    @Published var savedReports: [SavedReport] = []
    @Published var demo = false
    @Published var searchText = ""
    @Published var inspected = false
    @Published var log: [String] = []
    private var activity: NSObjectProtocol?
    private var demoRoot: URL?
    private var preparedPlan: BatchPlan?
    private var cancellation = CancellationToken()
    private var queueCancellation = CancellationToken()
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var observers: [NSObjectProtocol] = []
    private var queueLoadFailed = false
    private var lastDestinationSave = Date.distantPast
    private let store: TransferQueueStore

    init(queueDirectory: URL? = nil) {
        let defaultDirectory = (CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier?.hasPrefix("com.okcopy.ingest.preview") == true)
            ? FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Demo-Queue-" + UUID().uuidString)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OKCopy/Queue")
        store = TransferQueueStore(directory: queueDirectory ?? defaultDirectory)
        do { jobs = try store.load() }
        catch { queueLoadFailed = true; fail(IngestError("Could not restore the saved queue. Existing job data was preserved. " + error.localizedDescription)) }
        copyLayout = CopyLayout(rawValue: UserDefaults.standard.string(forKey: "copyLayout") ?? "") ?? .organized
        reportStorage = ReportStorage(rawValue: UserDefaults.standard.string(forKey: "reportStorage") ?? "") ?? .app
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        refreshCards()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCards() }
            })
        }
        runSafetyCheck()
        if (CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier?.hasPrefix("com.okcopy.ingest.preview") == true) { loadSample() }
    }
    var transferOptions: TransferOptions {
        var options = TransferOptions(cascade: cascade, concurrentSources: concurrentSources, manifests: exportManifests)
        options.layout = copyLayout; options.reportStorage = reportStorage; options.reportFolder = reportFolder
        return options
    }
    private func updateActivity() {
        if hasActiveWork && activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Verified copying") }
        if !hasActiveWork, let active = activity { ProcessInfo.processInfo.endActivity(active); activity = nil }
    }
    func rememberPreferences() {
        UserDefaults.standard.set(copyLayout.rawValue, forKey: "copyLayout")
        UserDefaults.standard.set(reportStorage == .destination ? "destination" : "app", forKey: "reportStorage")
    }
    var validationMessage: String? {
        if sources.isEmpty { return "Add a source folder to begin." }
        if destinations.isEmpty { return "Choose at least one destination." }
        if copyLayout != .destination { do { _ = try Planner.projectFolderName(projectName) } catch { return error.localizedDescription } }
        for source in sources { if (try? Planner.slug(source.label)) != source.label { return "Source labels use letters, numbers, hyphens and underscores." } }
        if reportStorage == .folder && reportFolder == nil { return "Choose a report folder." }
        if safety == nil { return "Waiting for sample safety checks." }
        return nil
    }
    func chooseReportFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose report folder"; panel.message = "Choose Desktop, Documents, or another folder."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK { reportFolder = panel.url; reportStorage = .folder; invalidate() }
    }
    func showSavedReports() {
        let folders = Set([CopyReports.appFolder] + jobs.flatMap { $0.reports.map { $0.deletingLastPathComponent() } })
        savedReports = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "html" }.map { url in
                let json = url.deletingPathExtension().appendingPathExtension("json")
                let object = (try? Data(contentsOf: json)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let plan = object?["plan"] as? [String: Any]
                return SavedReport(url: url, title: plan?["projectName"] as? String ?? url.deletingPathExtension().lastPathComponent, status: object?["status"] as? String ?? "Verification report", destinations: ((plan?["destinations"] as? [[String: Any]]) ?? []).compactMap { ($0["root"] as? String).flatMap(URL.init(string:))?.path }.joined(separator: "\n"), date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        }.sorted { $0.date > $1.date }
        showingHistory = true
    }
    func openSavedReport(_ report: SavedReport) {
        do { reportHTML = try String(contentsOf: report.url); reportURLs = [report.url]; showingHistory = false
            Task { try? await Task.sleep(nanoseconds: 250_000_000); showingReport = true }
        } catch { fail(error) }
    }
    func exportSavedReport(_ report: SavedReport) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = report.url.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            let actual = url.standardizedFileURL.resolvingSymlinksInPath()
            let protected = sources + jobs.flatMap { $0.plan.sources }
            guard !protected.contains(where: { actual.pathComponents.starts(with: $0.snapshot.protectedRoot.pathComponents) }) else { fail(IngestError("Reports cannot be exported onto a protected source.")); return }
            do { try Data(contentsOf: report.url).write(to: url, options: .atomic) } catch { fail(error) }
        }
    }
    func reverifySavedReport(_ report: SavedReport) {
        let json = report.url.deletingPathExtension().appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: json.path) else { fail(IngestError("This report has no checksum receipt. Choose an MHL or JSON receipt using Verify Manifest.")); return }
        showingHistory = false
        Task { try? await Task.sleep(nanoseconds: 250_000_000); verifyManifest(receipt: json) }
    }
    var hasActiveWork: Bool { busy || queueRunning }
    var visibleFiles: [CameraFile] { (snapshot?.files ?? []).filter { searchText.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(searchText) } }
    var selectedFile: CameraFile? { snapshot?.files.first { $0.id == selectedFileID } }
    var folderPreview: String {
        copyLayout == .destination ? "Selected destination" : projectName.isEmpty ? "Your folder name" : projectName
    }
    var canRun: Bool { !hasActiveWork && !sources.isEmpty && !destinations.isEmpty && (copyLayout == .destination || !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && (dryRun || (safety != nil && inspected && preparedPlan != nil && !queueLoadFailed)) }
    var canReview: Bool { !hasActiveWork && !sources.isEmpty && !destinations.isEmpty && (copyLayout == .destination || !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var canStart: Bool { validationMessage == nil && canReview && safety != nil && !queueLoadFailed }
    var canCopy: Bool { canReview && safety != nil && inspected && preparedPlan != nil && !queueLoadFailed }
    var outputFolderName: String { preparedPlan?.folderName ?? folderPreview }
    func reviewCopy() { guard canReview else { return }; invalidate(); run() }
    func copyPrepared() { guard canCopy else { return }; enqueuePrepared(startImmediately: true) }
    func startCopy() { prepareOrEnqueue(startImmediately: true) }
    func queueCopy() { prepareOrEnqueue(startImmediately: false) }
    private func prepareOrEnqueue(startImmediately: Bool) {
        guard canStart else { return }
        if canCopy { enqueuePrepared(startImmediately: startImmediately); return }
        let selections = sources; let targets = destinations; let name = projectName.isEmpty && copyLayout == .destination ? "Direct Copy" : projectName; let useIncremental = incremental
        let options = transferOptions
        invalidate(); busy = true; phase = "Preparing copy"; detail = "Checking paths and available space"; fraction = 0
        let token = CancellationToken(); cancellation = token
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try BatchPlanner.prepare(sources: selections, destinations: targets, projectName: name,
                        incremental: useIncremental, options: options, hashDuringCopy: true, token: token)
                }.value
                try token.check()
                preparedPlan = plan; busy = false
                enqueuePrepared(startImmediately: startImmediately)
            } catch { busy = false; fail(error) }
        }
    }
    func queuePrepared() { guard canCopy else { return }; enqueuePrepared() }
    var waitingCount: Int { jobs.filter { $0.status == .queued || $0.status == .paused || $0.status == .failed }.count }

    func refreshCards() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        cards = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false else { return nil }
            return MountedCard(url: url, name: values.volumeName ?? url.lastPathComponent, hasDCIM: FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path))
        }.sorted { ($0.hasDCIM ? "0" : "1") + $0.name < ($1.hasDCIM ? "0" : "1") + $1.name }
    }
    func chooseSource() {
        let panel = NSOpenPanel(); panel.title = "Choose source folders"
        panel.message = "Choose one or more sources. OK, Copy never writes to them."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; panel.canCreateDirectories = false
        if panel.runModal() == .OK { addSources(panel.urls, sample: false) }
    }
    func chooseDestination(replacing index: Int? = nil) {
        let panel = NSOpenPanel(); panel.title = "Choose destination folders"
        panel.message = "Internal storage and connected drives are supported. One destination is enough."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = index == nil; panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            if let index, let url = panel.url, destinations.indices.contains(index) { destinations[index] = url }
            else { for url in panel.urls where !destinations.contains(url) { destinations.append(url) } }
            invalidate()
        }
    }
    func removeDestination(_ index: Int) { if destinations.indices.contains(index) { destinations.remove(at: index); invalidate() } }
    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }; invalidate()
        if selectedSourceID == id { if let first = sources.first { selectPreview(first.id) } else { snapshot = nil; selectedSourceID = nil; selectedFileID = nil; thumbnail = nil } }
    }
    func updateLabel(_ id: UUID, label: String) { if let index = sources.firstIndex(where: { $0.id == id }) { sources[index].label = label; invalidate() } }
    func invalidate() {
        rememberPreferences()
        inspected = false; preparedPlan = nil; dryRun = true
        resultMessage = nil; errorMessage = nil; reportURLs = []; reportHTML = nil
        if !hasActiveWork {
            fraction = 0
            phase = sources.isEmpty ? "Choose sources to begin" : "Ready to copy"
            detail = "Start copying now, or choose Review Copy for an optional preview."
        }
    }
    func selectSource(_ url: URL, sample: Bool) { addSources([url], sample: sample) }
    func addSources(_ urls: [URL], sample: Bool) {
        guard !hasActiveWork else { return }
        if demo && !sample { sources = []; destinations = []; snapshot = nil; selectedSourceID = nil; projectName = "" }
        demo = sample; invalidate(); busy = true; errorMessage = nil; phase = "Scanning sources"; fraction = 0
        let token = CancellationToken(); cancellation = token
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) { try urls.map { try CardScanner.scan($0, token: token) } }.value
                for result in results {
                    if let old = sources.first(where: { $0.snapshot.root == result.root }) { selectPreview(old.id); continue }
                    let base = (try? Planner.slug(result.root.lastPathComponent)) ?? "Camera-Card"
                    var label = base; var counter = 2
                    while sources.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) { label = base + "-" + String(counter); counter += 1 }
                    let selection = SourceSelection(snapshot: result, label: label)
                    sources.append(selection); selectPreview(selection.id)
                    if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { projectName = result.root.lastPathComponent }
                    log.append("Added source \(result.root.path): \(result.files.count) files")
                    if let excluded = result.excludedPaths, !excluded.isEmpty { log.append("Skipped macOS housekeeping: " + excluded.joined(separator: ", ")) }
                }
                phase = "Ready to copy"; detail = "\(sources.count) sources selected · source labels keep their files separate"
            } catch { fail(error) }
            busy = false
        }
    }
    func selectPreview(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        selectedSourceID = id; snapshot = source.snapshot; thumbnail = nil
        selectedFileID = (source.snapshot.files.first { $0.kind == "Photo" } ?? source.snapshot.files.first)?.id
        previewSelection()
    }
    func previewSelection() {
        if let old = thumbnailRequest { QLThumbnailGenerator.shared.cancel(old) }; thumbnail = nil
        guard let file = selectedFile, let root = snapshot?.root else { return }
        let id = file.id; let sourceID = selectedSourceID
        let request = QLThumbnailGenerator.Request(fileAt: root.appendingPathComponent(file.relativePath), size: CGSize(width: 800, height: 600), scale: 2, representationTypes: .thumbnail)
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            Task { @MainActor in guard self?.selectedFileID == id, self?.selectedSourceID == sourceID else { return }; self?.thumbnail = representation?.nsImage }
        }
    }
    func runSafetyCheck() {
        guard !safetyRunning, !hasActiveWork else { return }
        safetyRunning = true; safety = nil; dryRun = true
        Task {
            do { safety = try await Task.detached(priority: .userInitiated) { try SafetyCheck.run() }.value; log.append("Sample safety checks passed") }
            catch { fail(error) }
            safetyRunning = false
        }
    }
    func run() {
        guard canRun else { return }
        if !dryRun { enqueuePrepared(); return }
        let selections = sources; let targets = destinations; let name = projectName.isEmpty && copyLayout == .destination ? "Direct Copy" : projectName; let useIncremental = incremental
        let options = transferOptions
        busy = true; errorMessage = nil; resultMessage = nil; reportURLs = []; reportHTML = nil; fraction = 0
        phase = "Reviewing copy"
        let token = CancellationToken(); cancellation = token
        let relay = ProgressRelay { [weak self] value in Task { @MainActor in guard self?.busy == true else { return }; self?.apply(value) } }
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try BatchPlanner.prepare(sources: selections, destinations: targets, projectName: name, incremental: useIncremental, options: options, token: token, progress: { relay.receive($0) })
                }.value
                let html = BatchReport.dryRun(plan)
                let reportFolder = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Reports-" + UUID().uuidString)
                for source in plan.sources {
                    guard !reportFolder.resolvingSymlinksInPath().pathComponents.starts(with: source.snapshot.protectedRoot.pathComponents) else { throw IngestError("Temporary report location overlaps a source. Choose a narrower source folder.") }
                }
                try FileManager.default.createDirectory(at: reportFolder, withIntermediateDirectories: false)
                let report = reportFolder.appendingPathComponent("Dry Run Report.html")
                try Data(html.utf8).write(to: report, options: .withoutOverwriting)
                preparedPlan = plan; inspected = true; reportHTML = html; reportURLs = [report]
                resultMessage = "Review complete. \(plan.sources.count) sources, \(plan.destinations.count) destinations. \(plan.existingCopies) existing copies match; \(plan.duplicateCount) duplicate-content files. " + plan.warnings.joined(separator: " ")
                dryRun = false; phase = "Ready to copy"; detail = "Review the report, then start this copy or add it to the queue."; fraction = 1
            } catch { fail(error) }
            busy = false
        }
    }
    private func enqueuePrepared(startImmediately: Bool = false) {
        guard let plan = preparedPlan, !queueLoadFailed else { return }
        if demo {
            guard let demoRoot, plan.destinations.allSatisfy({ $0.root.pathComponents.starts(with: demoRoot.pathComponents) }), plan.sources.allSatisfy({ $0.snapshot.root.pathComponents.starts(with: demoRoot.pathComponents) }) else {
                fail(IngestError("Sample copies can only use the generated sample workspace. Add your own sources for a normal copy.")); return
            }
        }
        let job = TransferJob(plan: plan); var next = jobs; next.append(job)
        do {
            try store.save(next); jobs = next; invalidate(); showingQueue = true
            phase = "Added to queue"; detail = "Start the queue when your sources and destinations are connected."
            if startImmediately { runQueue(only: job.id) }
        }
        catch { fail(error) }
    }
    func startQueue() { runQueue(only: nil) }
    private func runQueue(only jobID: UUID?) {
        guard !hasActiveWork, safety != nil, !queueLoadFailed, jobs.contains(where: { $0.status == .queued && (jobID == nil || $0.id == jobID) }) else { return }
        queueRunning = true; errorMessage = nil; queueCancellation = CancellationToken()
        Task {
            while let index = jobs.firstIndex(where: { $0.status == .queued && (jobID == nil || $0.id == jobID) }), !queueCancellation.isCancelled {
                jobs[index].status = .running; jobs[index].lastError = nil
                let job = jobs[index]; activeJobID = job.id
                do {
                    try store.save(jobs)
                    let token = queueCancellation
                    let relay = ProgressRelay { [weak self] value in Task { @MainActor in
                        guard let self, self.activeJobID == job.id, self.queueRunning else { return }
                        self.apply(value)
                        if let at = self.jobs.firstIndex(where: { $0.id == job.id }) { self.jobs[at].finishedFiles = value.completedFiles }
                    } }
                    let result = try await Task.detached(priority: .userInitiated) {
                        try TransferEngine.run(job, token: token, progress: { relay.receive($0) }, destinations: { [weak self] values in
                            Task { @MainActor in
                                guard let self, self.activeJobID == job.id, let at = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                                self.jobs[at].destinationProgress = values
                                if Date().timeIntervalSince(self.lastDestinationSave) > 2 {
                                    do { try self.store.save(self.jobs); self.lastDestinationSave = Date() }
                                    catch { self.log.append("Could not checkpoint destination status: " + error.localizedDescription) }
                                }
                            }
                        })
                    }.value
                    guard let at = jobs.firstIndex(where: { $0.id == job.id }) else { break }
                    jobs[at].destinationProgress = result.destinations
                    jobs[at].status = .completed; jobs[at].finishedFiles = result.files.count; jobs[at].reports = result.reports
                    activeJobID = nil; try store.save(jobs)
                    reportHTML = result.html; reportURLs = result.reports
                    resultMessage = "\(result.files.count) files verified at \(job.plan.destinations.count) destinations."
                    phase = "Job complete"; detail = job.plan.projectName; fraction = 1
                    log.append("Completed queue job: " + job.plan.projectName)
                    notify("Copy verified", message: job.plan.projectName)
                    NSApp?.requestUserAttention(.informationalRequest)
                } catch {
                    if let at = jobs.firstIndex(where: { $0.id == job.id }) {
                        jobs[at].status = queueCancellation.isCancelled ? .paused : .failed; jobs[at].lastError = error.localizedDescription
                        jobs[at].reports = (error as? IngestError)?.reports ?? []
                        if let values = (error as? IngestError)?.destinations { jobs[at].destinationProgress = values }
                    }
                    activeJobID = nil
                    do { try store.save(jobs) } catch { log.append("Could not save queue status: " + error.localizedDescription) }
                    fail(error); phase = queueCancellation.isCancelled ? "Queue paused · resume when ready" : "Queue stopped · needs attention"
                    break
                }
            }
            activeJobID = nil; queueRunning = false
        }
    }
    func resumeJob(_ id: UUID) {
        guard !hasActiveWork, let at = jobs.firstIndex(where: { $0.id == id }), jobs[at].status != .completed else { return }
        jobs[at].status = .queued
        do { try store.save(jobs); runQueue(only: id) } catch { fail(error) }
    }
    func moveJob(_ id: UUID, offset: Int) {
        guard !hasActiveWork, let index = jobs.firstIndex(where: { $0.id == id }), jobs.indices.contains(index + offset) else { return }
        jobs.swapAt(index, index + offset); do { try store.save(jobs) } catch { fail(error) }
    }
    func forgetJob(_ id: UUID) {
        guard !hasActiveWork else { return }; let next = jobs.filter { $0.id != id }
        do { try store.save(next); jobs = next } catch { fail(error) }
    }
    func showJobReport(_ job: TransferJob) {
        guard let first = job.reports.first else { return }
        do {
            reportHTML = try String(contentsOf: first, encoding: .utf8); reportURLs = job.reports; showingQueue = false
            Task { try? await Task.sleep(nanoseconds: 250_000_000); showingReport = true }
        } catch { fail(error) }
    }
    func verifyManifest() { verifyManifest(receipt: nil) }
    func verifyManifest(receipt: URL?) {
        guard !hasActiveWork else { return }
        let panel = NSOpenPanel(); panel.title = "Choose an MHL manifest or OK, Copy JSON receipt"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let manifest: URL
        if let receipt { manifest = receipt } else { guard panel.runModal() == .OK, let selected = panel.url else { return }; manifest = selected }
        let folder = NSOpenPanel(); folder.title = "Choose the folder containing the listed originals"
        folder.message = "Choose the project root. Verification only reads files and never repairs or changes them."
        folder.canChooseFiles = false; folder.canChooseDirectories = true; folder.canCreateDirectories = false
        folder.directoryURL = manifest.deletingLastPathComponent()
        guard folder.runModal() == .OK, let root = folder.url else { return }
        busy = true; errorMessage = nil; phase = "Verifying manifest"; fraction = 0
        let token = CancellationToken(); cancellation = token
        let relay = ProgressRelay { [weak self] value in Task { @MainActor in self?.apply(value) } }
        Task {
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try MediaManifest.verify(manifest: manifest, root: root, token: token, progress: { relay.receive($0) })
                }.value
                reportHTML = summary.html; reportURLs = []
                let location = CopyReports.appFolder.standardizedFileURL.resolvingSymlinksInPath()
                if !location.pathComponents.starts(with: root.standardizedFileURL.resolvingSymlinksInPath().pathComponents) && !root.standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: location.pathComponents) {
                    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
                    let saved = location.appendingPathComponent("Verification-" + UUID().uuidString + ".html")
                    try Data(summary.html.utf8).write(to: saved, options: .withoutOverwriting); reportURLs = [saved]
                }
                showingReport = true
                resultMessage = summary.passed ? "All listed files verified." : "Verification found missing, changed, or unsupported entries. Review the report."
                phase = summary.passed ? "Verification complete" : "Verification needs attention"
            } catch { fail(error) }
            busy = false
        }
    }
    func configureNotifications() {
        guard notificationsEnabled else { UserDefaults.standard.set(false, forKey: "notificationsEnabled"); return }
        Task {
            do { notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
            catch { notificationsEnabled = false; log.append("Notifications unavailable: " + error.localizedDescription) }
        }
    }
    private func notify(_ title: String, message: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    func presentReportWindow() {
        if reportWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "OK, Copy · Report"; window.minSize = NSSize(width: 650, height: 420)
            window.isReleasedWhenClosed = false; window.center(); window.setFrameAutosaveName("ReportWindow")
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            window.contentView = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
            reportWindow = window
        }
        (reportWindow?.contentView as? WKWebView)?.loadHTMLString(reportHTML ?? "<p>No report available.</p>", baseURL: nil)
        reportWindow?.makeKeyAndOrderFront(nil)
    }
    func retryJobReports(_ job: TransferJob) {
        guard !hasActiveWork else { return }; busy = true; phase = "Exporting saved receipts"
        Task {
            defer { busy = false }
            do {
                let urls = try await Task.detached { try TransferEngine.retryReports(job) }.value
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].reports += urls
                    if !urls.isEmpty, jobs[index].destinationProgress?.allSatisfy({ $0.phase.hasPrefix("Verified") }) == true {
                        jobs[index].status = .completed; jobs[index].lastError = nil
                        jobs[index].destinationProgress = jobs[index].destinationProgress?.map { value in var updated = value; updated.phase = "Verified"; updated.error = nil; return updated }
                    }
                    try store.save(jobs) }
                resultMessage = urls.isEmpty ? "No pending reports for this job." : "Saved \(urls.count) recovered reports. These describe the original verification; use Reverify for a fresh check."
                phase = "Report export finished"
            } catch { fail(error) }
        }
    }
    func showQueueFolder() { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
    func apply(_ value: IngestProgress) { phase = value.phase; detail = value.path; fraction = value.fraction; completedFiles = value.completedFiles }
    func stop() {
        if queueRunning { queueCancellation.cancel(); phase = "Pausing safely…" }
        else { cancellation.cancel(); phase = "Stopping preparation…" }
    }
    func fail(_ error: Error) {
        errorMessage = error.localizedDescription; phase = "Needs attention"; detail = "Source files were not changed."
        if let values = (error as? IngestError)?.destinations {
            let verified = values.filter { $0.phase.hasPrefix("Verified") || $0.phase.hasPrefix("Working copy verified") }.count
            let failed = values.filter { $0.error != nil }.map { $0.root.lastPathComponent }.joined(separator: ", ")
            detail = "\(verified) of \(values.count) destinations verified. " + (failed.isEmpty ? "" : "Reconnect or inspect \(failed). ") + "Resume rechecks healthy copies and retries unfinished work."
        }
        if let ingest = error as? IngestError { reportURLs = ingest.reports; if let first = ingest.reports.first { reportHTML = try? String(contentsOf: first, encoding: .utf8) } }
        log.append(error.localizedDescription)
        notify("Copy needs attention", message: error.localizedDescription)
        NSApp?.requestUserAttention(.informationalRequest)
    }
    func openReport() { if reportHTML != nil { showingReport = true } }
    func revealReport() { NSWorkspace.shared.activateFileViewerSelecting(reportURLs) }
    func loadSample() {
        guard !hasActiveWork else { return }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("OKCopy-Demo-" + UUID().uuidString)
            let cardA = root.appendingPathComponent("SAMPLE-A"); let cardB = root.appendingPathComponent("SAMPLE-B")
            let images = cardA.appendingPathComponent("DCIM/100FIELD"); let other = cardB.appendingPathComponent("DCIM/100FIELD")
            let targets = ["Working-SSD", "Backup-Drive", "Extra-Copy"].map { root.appendingPathComponent($0) }
            for url in [images, other] + targets { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            for i in 0..<4 { try sampleJPEG(index: i).write(to: images.appendingPathComponent(String(format: "DSC_%04d.JPG", 2401 + i))) }
            try Data(contentsOf: images.appendingPathComponent("DSC_2401.JPG")).write(to: other.appendingPathComponent("DSC_2401.JPG"))
            try sampleJPEG(index: 4).write(to: other.appendingPathComponent("DSC_2501.JPG"))
            try Data("<xmpmeta>OK, Copy synthetic sidecar</xmpmeta>".utf8).write(to: images.appendingPathComponent("DSC_2401.XMP"))
            sources = []; snapshot = nil; destinations = targets; projectName = "Sample Coastal Light"; demoRoot = root
            addSources([cardA, cardB], sample: true)
        } catch { fail(error) }
    }
}

final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let callback: @Sendable (IngestProgress) -> Void
    init(callback: @escaping @Sendable (IngestProgress) -> Void) { self.callback = callback }
    func receive(_ value: IngestProgress) {
        lock.lock(); let now = Date(); let send = now.timeIntervalSince(last) > 0.09 || value.fraction >= 1
        if send { last = now }; lock.unlock()
        if send { callback(value) }
    }
}

@MainActor private func sampleJPEG(index: Int) throws -> Data {
    let width = 1200, height = 800
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IngestError("Could not create demo image") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let palettes: [(NSColor, NSColor)] = [(.init(red: 0.8, green: 0.85, blue: 0.81, alpha: 1), .init(red: 0.24, green: 0.45, blue: 0.47, alpha: 1)), (.init(red: 0.94, green: 0.73, blue: 0.51, alpha: 1), .init(red: 0.35, green: 0.42, blue: 0.45, alpha: 1)), (.init(red: 0.69, green: 0.77, blue: 0.83, alpha: 1), .init(red: 0.19, green: 0.32, blue: 0.36, alpha: 1))]
    let (sky, sea) = palettes[index % 3]
    NSGradient(starting: sea, ending: sky)?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
    sky.blended(withFraction: 0.55, of: .white)!.setFill()
    NSBezierPath(ovalIn: NSRect(x: 820 - index * 65, y: 520, width: 75, height: 75)).fill()
    for layer in 0..<3 {
        sea.blended(withFraction: CGFloat(layer) * 0.16, of: .black)!.setFill()
        let p = NSBezierPath(); p.move(to: .zero)
        p.line(to: CGPoint(x: 0, y: 210 + layer * 65))
        p.curve(to: CGPoint(x: 1200, y: 90 + layer * 75), controlPoint1: CGPoint(x: 250 + index * 30, y: 650 - layer * 85), controlPoint2: CGPoint(x: 460, y: 60 + layer * 60))
        p.line(to: CGPoint(x: 1200, y: 0)); p.close(); p.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.87]) else { throw IngestError("Could not encode demo image") }
    return data
}

struct SavedReport: Identifiable {
    let url: URL; let title: String; let status: String; let destinations: String; let date: Date
    var id: String { url.path }
}
