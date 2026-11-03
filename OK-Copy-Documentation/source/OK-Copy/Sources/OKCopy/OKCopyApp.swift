import SwiftUI
import AppKit
import IngestCore
import WebKit

struct OKCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("OK, Copy") {
            ContentView(model: model)
                .frame(minWidth: 1120, minHeight: 760)
                .tint(.purple)
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Sources…", action: model.chooseSource).keyboardShortcut("o").disabled(model.hasActiveWork)
                Button("Try Sample Copy", action: model.loadSample).disabled(model.hasActiveWork)
            }
            CommandMenu("Copy") {
                Button("Start Copy", action: model.startCopy).disabled(!model.canStart)
                Button("Review Copy", action: model.reviewCopy).keyboardShortcut("r").disabled(!model.canReview)
                Button("Transfer Queue") { model.showingQueue = true }.keyboardShortcut("j")
                Button(model.queueRunning ? "Pause Queue" : "Stop", action: model.stop).keyboardShortcut(".").disabled(!model.hasActiveWork)
                Divider()
                Button("Run Sample Safety Check", action: model.runSafetyCheck).disabled(model.hasActiveWork || model.safetyRunning)
                Button("Open Report", action: model.openReport).disabled(model.reportHTML == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.hasActiveWork == true {
            // Prevent closing the process in the middle of its reporting and flush steps.
            let alert = NSAlert(); alert.messageText = "Pause copying and quit?"; alert.informativeText = "Verified copies and recovery data will be retained."
            alert.addButton(withTitle: "Pause and Quit"); alert.addButton(withTitle: "Keep Copying")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            model?.stop()
            Task { @MainActor in
                while self.model?.hasActiveWork == true { try? await Task.sleep(nanoseconds: 100_000_000) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showLog = false
    @State private var showChecks = false
    @State private var showPreview = false
    @State private var showCameraOptions = false
    @State private var showAdvancedOptions = false
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector.frame(width: 340)
                }
                Divider()
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("OK, Copy")
            .navigationSubtitle(model.sources.isEmpty ? "Verified Copying Tool" : "\(model.sources.count) sources · \(model.destinations.count) destinations")
            .toolbar { copyToolbar }

        }
        .onChange(of: model.selectedFileID) { _, _ in model.previewSelection() }
        .onChange(of: model.projectName) { _, _ in model.invalidate() }
        .onChange(of: model.copyLayout) { _, _ in model.invalidate() }
        .onChange(of: model.reportStorage) { _, _ in model.invalidate() }
        .onChange(of: model.cascade) { _, _ in model.invalidate() }
        .onChange(of: model.concurrentSources) { _, _ in model.invalidate() }
        .onChange(of: model.exportManifests) { _, _ in model.invalidate() }
        .onChange(of: model.incremental) { _, _ in model.invalidate() }
        .sheet(isPresented: $model.showingHistory) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Saved Reports").font(.title2.bold()); Spacer(); Button("Done") { model.showingHistory = false } }
                if model.savedReports.isEmpty { Text("No saved reports yet.").foregroundStyle(.secondary) }
                List(model.savedReports) { report in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.title).font(.headline)
                        Text(report.date.formatted() + " · " + report.status).font(.caption)
                        Text(report.destinations).font(.caption).textSelection(.enabled)
                        Text(report.url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Open") { model.openSavedReport(report) }
                            Button("Export…") { model.exportSavedReport(report) }
                            Button("Reverify…") { model.reverifySavedReport(report) }.disabled(model.hasActiveWork)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.url]) }
                        }
                    }.buttonStyle(.borderless).padding(.vertical, 6)
                }
            }.padding(24).frame(width: 850, height: 580)
        }
        .sheet(isPresented: $model.showingQueue) { QueueView(model: model) }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Activity").font(.title2.bold())
                ScrollView { Text(model.log.isEmpty ? "No activity yet." : model.log.joined(separator: "\n\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                Button("Done") { showLog = false }.frame(maxWidth: .infinity, alignment: .trailing).keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 670, height: 420)
        }
        .sheet(isPresented: $showChecks) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Sample safety check", systemImage: "checkmark.shield.fill").font(.title2.bold())
                Text("Generated test files are copied and verified in a temporary folder. Your selected sources are never used for this check.").foregroundStyle(.secondary)
                ForEach(model.safety?.checks ?? [], id: \.self) { check in Label(check, systemImage: "checkmark.circle.fill").foregroundStyle(.purple) }
                HStack { Button("Run Again", action: model.runSafetyCheck).disabled(model.hasActiveWork || model.safetyRunning); Spacer(); Button("Done") { showChecks = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 590)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 23, weight: .medium)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OK, Copy").font(.title3.weight(.semibold))
                    Text("VERIFIED COPYING TOOL").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                }
            }.padding(20)
            HStack {
                Text("FROM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.sources.count) sources").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 12)
            Button(action: model.chooseSource) {
                Label("Add Folders…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
            }.controlSize(.large).disabled(model.hasActiveWork).padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose what to copy").font(.callout.weight(.medium))
                            Text("Select a folder on your Mac, an external drive, or a camera card.").font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                    ForEach(model.sources) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button { model.selectPreview(source.id) } label: {
                                    Label(source.snapshot.root.lastPathComponent, systemImage: "folder.fill")
                                        .font(.callout.weight(.medium)).lineLimit(1)
                                }.buttonStyle(.plain)
                                Spacer(minLength: 0)
                                Button { model.removeSource(source.id) } label: { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.plain).accessibilityLabel("Remove source " + source.label).help("Remove source from this copy")
                            }
                            Text(source.snapshot.root.path).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle).help(source.snapshot.root.path)
                            Text("\(source.snapshot.files.count) files · \(bytes(source.snapshot.totalBytes))").font(.caption2).foregroundStyle(.secondary)
                            if let excluded = source.snapshot.excludedPaths, !excluded.isEmpty {
                                Text("\(excluded.count) macOS housekeeping entries skipped").font(.caption2).foregroundStyle(.secondary)
                                    .help(excluded.joined(separator: "\n"))
                            }
                            Text(model.sources.count == 1 && model.copyLayout != .organized ? "Label (unused in this layout)" : "Source label").font(.caption2).foregroundStyle(.secondary)
                            TextField("Folder label", text: Binding(get: { model.sources.first(where: { $0.id == source.id })?.label ?? source.label }, set: { model.updateLabel(source.id, label: $0) }))
                                .textFieldStyle(.roundedBorder).font(.caption)
                        }.padding(12)
                        .background(model.selectedSourceID == source.id ? Color.purple.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .disabled(model.hasActiveWork)
                    }
                    Divider().padding(.vertical, 4)
                    HStack {
                        Text("CONNECTED DRIVES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: model.refreshCards) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh connected drives")
                    }.padding(.horizontal, 8)
                    ForEach(model.cards) { card in
                        Button { model.selectSource(card.url, sample: false) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: card.hasDCIM ? "sdcard" : "externaldrive").font(.title3).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.name).font(.callout).lineLimit(1)
                                    Text(card.hasDCIM ? "Camera folder detected" : "External volume").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.hasActiveWork)
                    }
                    if model.cards.isEmpty {
                        Text("No external drives connected").font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }.padding(.horizontal, 10)
            }
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 12) {
                Button { showChecks = true } label: {
                    Label(model.safetyRunning ? "Checking sample files…" : model.safety == nil ? "Safety check needed" : "Safety checks passed",
                          systemImage: model.safety == nil ? "hourglass" : "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }.padding(18)
        }.background(.thinMaterial)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy with confidence.").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(model.snapshot == nil ? "Folders, drives, or camera cards. Every copy verified." : "Choose where your files go, then start copying. Review is optional.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.demo { Text("SAMPLE COPY").font(.system(size: 9, weight: .bold)).tracking(1).padding(.horizontal, 10).padding(.vertical, 6).background(.purple.opacity(0.12), in: Capsule()).foregroundStyle(.purple) }
            }.padding(24)
            if model.snapshot != nil {
                DisclosureGroup("File preview", isExpanded: $showPreview) {
                    preview.padding(.top, 10)
                }.font(.callout).padding(.horizontal, 24).padding(.bottom, 16)
            }
            HStack {
                Text(model.snapshot?.root.lastPathComponent ?? "Source files").font(.headline)
                if let snapshot = model.snapshot { Text("\(snapshot.files.count) files · \(bytes(snapshot.totalBytes))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter files", text: $model.searchText).textFieldStyle(.plain).frame(width: 110)
            }.padding(.horizontal, 24).padding(.bottom, 12)
            if model.snapshot != nil {
                Table(model.visibleFiles, selection: $model.selectedFileID) {
                    TableColumn("Name") { file in
                        HStack(spacing: 8) { Image(systemName: file.kind == "Video" ? "film" : file.kind == "Other" ? "doc" : "photo").foregroundStyle(.secondary); Text(file.name).lineLimit(1) }
                    }.width(min: 150, ideal: 190)
                    TableColumn("Type") { file in Text(file.fileExtension).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }.width(45)
                    TableColumn("Size") { file in Text(bytes(file.bytes)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
                    TableColumn("Folder") { file in Text((file.relativePath as NSString).deletingLastPathComponent).foregroundStyle(.secondary).lineLimit(1) }
                }.tableStyle(.inset).disabled(model.hasActiveWork)
            } else {
                ContentUnavailableView("Start with a source folder", systemImage: "folder.badge.plus", description: Text("Choose Add Folders on the left. Documents, photos, videos, and other regular files are included.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) { Image(systemName: "info.circle"); Text("Known macOS housekeeping is skipped. Other hidden files are included.") }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor))
            if let image = model.thumbnail {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).padding(8)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: model.selectedFile?.kind == "Other" ? "doc.text" : "camera.aperture").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text(model.selectedFile == nil ? "A little clarity before you copy." : "Preview unavailable for this file type").font(.callout).foregroundStyle(.secondary)
                    if model.selectedFile != nil { Text("The original will still be included.").font(.caption).foregroundStyle(.tertiary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let file = model.selectedFile {
                HStack(spacing: 6) { Text(file.name).fontWeight(.medium); Text("· \(file.kind)").foregroundStyle(.secondary) }.font(.caption).padding(.horizontal, 10).padding(.vertical, 7).background(.regularMaterial, in: Capsule()).padding(14)
            }
        }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    @ToolbarContentBuilder private var copyToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { Button("Transfer Queue (\(model.waitingCount))", action: { model.showingQueue = true }).buttonStyle(CopyToolbarButtonStyle()).accessibilityLabel("Transfer Queue") }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { Button("Verify Manifest…", action: { model.verifyManifest() }).buttonStyle(CopyToolbarButtonStyle()).accessibilityLabel("Verify Manifest").disabled(model.hasActiveWork) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { Button("Activity", action: { showLog.toggle() }).buttonStyle(CopyToolbarButtonStyle()).accessibilityLabel("Activity") }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { Button("Transfer Queue (\(model.waitingCount))", action: { model.showingQueue = true }).buttonStyle(CopyToolbarButtonStyle()).accessibilityLabel("Transfer Queue") }
            ToolbarItem(placement: .primaryAction) { Button("Verify Manifest…", action: { model.verifyManifest() }).buttonStyle(CopyToolbarButtonStyle()).accessibilityLabel("Verify Manifest").disabled(model.hasActiveWork) }
            ToolbarItem(placement: .primaryAction) { Button("Activity", action: { showLog.toggle() }).buttonStyle(CopyToolbarButtonStyle()).accessibilityLabel("Activity") }
        }
    }

    private var folderLayoutPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            treeRow(model.copyLayout == .destination ? (model.destinations.first?.lastPathComponent ?? "Destination folder") : (model.projectName.isEmpty ? "Your folder name" : model.projectName), depth: 0)
            if model.copyLayout == .organized {
                treeRow("Originals", depth: 1)
                if model.sources.isEmpty {
                    treeRow("Source folder", depth: 2)
                    treeRow("Your files and subfolders", depth: 3, files: true)
                } else {
                    ForEach(model.sources) { source in
                        treeRow(source.label, depth: 2)
                        treeRow("Your files and subfolders", depth: 3, files: true)
                    }
                }
            } else if model.sources.count > 1 {
                ForEach(model.sources) { source in
                    treeRow(source.label, depth: 1)
                    treeRow("Your files and subfolders", depth: 2, files: true)
                }
            } else {
                treeRow("Your files and subfolders", depth: 1, files: true)
            }
            if model.reportStorage == .destination {
                treeRow("Ingest Reports", depth: 1, files: true)
            }
            if model.exportManifests {
                treeRow("Checksum manifests (.mhl)", depth: 1, files: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destination folder structure preview")
    }

    private func treeRow(_ title: String, depth: Int, files: Bool = false) -> some View {
        Label(title, systemImage: files ? "doc.text" : "folder")
            .font(.caption.weight(depth == 0 ? .semibold : .regular))
            .foregroundStyle(files ? Color.secondary : Color.primary)
            .padding(.leading, CGFloat(depth * 14))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("TO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Choose destinations").font(.title3.weight(.semibold))
                    Text("Copy to one or more folders on your Mac or connected drives.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(model.destinations.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 8) {
                            destination(model.cascade && index == 0 ? "Working copy · first" : "Destination \(index + 1)", subtitle: "", icon: "folder", url: url, index: index)
                            Button { model.removeDestination(index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.hasActiveWork).accessibilityLabel("Remove destination \(index + 1)").help("Remove destination")
                        }
                    }
                    Button { model.chooseDestination() } label: { Label("Add Destination…", systemImage: "folder.badge.plus") }.disabled(model.hasActiveWork)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Folder layout").font(.headline)
                    Picker("Copy layout", selection: $model.copyLayout) {
                        Text("Organized: Originals > Source Folders").tag(CopyLayout.organized)
                        Text("Into Folder").tag(CopyLayout.folder)
                        Text("Directly into destination folder").tag(CopyLayout.destination)
                    }.labelsHidden().disabled(model.hasActiveWork)
                    if model.copyLayout != .destination {
                        TextField("Exact folder name", text: $model.projectName).textFieldStyle(.roundedBorder).disabled(model.hasActiveWork)
                    }
                    Text(model.copyLayout == .destination ? "Copies into each selected folder. One source keeps its relative paths; multiple sources get separate source folders." : model.copyLayout == .folder ? "Creates your named folder. One source keeps its relative paths; multiple sources get separate source folders." : "Creates your named folder with Originals and a folder for each source.").font(.caption).foregroundStyle(.secondary)
                    folderLayoutPreview
                    if model.destinations.count > 1 {
                        Text("This structure is used at every destination.").font(.caption2).foregroundStyle(.secondary)
                    }
                    if model.reportStorage != .destination {
                        Label(model.reportStorage == .app ? "Reports kept in app" : "Reports saved to " + (model.reportFolder?.lastPathComponent ?? "your chosen folder"), systemImage: "doc.text")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Files may appear before verification finishes. Wait for Verified in the queue. A hidden .OKCopy folder keeps recovery information.").font(.caption2).foregroundStyle(.secondary)
                    Picker("Reports", selection: $model.reportStorage) {
                        Text("Keep in app").tag(ReportStorage.app)
                        Text("Selected report folder").tag(ReportStorage.folder)
                        Text("Destination folders").tag(ReportStorage.destination)
                    }.disabled(model.hasActiveWork)
                    if model.reportStorage == .folder {
                        Button(model.reportFolder?.path ?? "Choose report folder…", action: model.chooseReportFolder).font(.caption).disabled(model.hasActiveWork)
                    }
                    Button("Show Saved Reports", action: model.showSavedReports).font(.caption)

                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let message = model.validationMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                    DisclosureGroup("Output paths") { Text(model.destinations.map { $0.appendingPathComponent(model.copyLayout == .destination ? "" : model.folderPreview).path }.joined(separator: "\n")).font(.caption2).textSelection(.enabled) }
                    Text("Copy options").font(.headline)
                    Toggle("Completion notifications", isOn: $model.notificationsEnabled).onChange(of: model.notificationsEnabled) { _, _ in model.configureNotifications() }
                    Text("Review Copy is optional. Start Copy calculates checksums as it copies and verifies each destination afterward.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Skip verified matching files", isOn: $model.incremental).disabled(model.hasActiveWork)
                    Text("Existing files are checked again. Different content at the same path is reported as a conflict.").font(.caption2).foregroundStyle(.secondary)
                    Label("SHA-256 verification always on", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.purple)
                    Label("Source files stay untouched", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(isExpanded: $showCameraOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Export MHL + ASC MHL", isOn: $model.exportManifests).disabled(model.hasActiveWork)
                        Text("Add checksum manifests for camera and post-production workflows. SHA-256 verification and copy reports are included either way.").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Camera options").font(.callout.weight(.medium))
                        Text(model.exportManifests ? "MHL manifests enabled" : "Optional manifest export").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup(isExpanded: $showAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Cascade from first destination", isOn: $model.cascade).disabled(model.hasActiveWork)
                        Text("Verify destination 1 first, then use it as the source for the remaining copies.").font(.caption2).foregroundStyle(.secondary)
                        Stepper("Concurrent sources: \(model.concurrentSources)", value: $model.concurrentSources, in: 1...4).disabled(model.hasActiveWork)
                        Text("Sources sharing a detected drive or connection are grouped to limit contention.").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Advanced options").font(.callout.weight(.medium))
                        Text(model.cascade ? "Cascading enabled" : "Direct copying · \(model.concurrentSources) concurrent sources").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) { Label("Needs attention", systemImage: "exclamationmark.triangle.fill").font(.callout.bold()); Text(error).font(.caption).textSelection(.enabled) }.foregroundStyle(.red).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
                if let result = model.resultMessage {
                    VStack(alignment: .leading, spacing: 8) { Label("Copy status", systemImage: "info.circle").font(.callout.bold()); Text(result).font(.caption).textSelection(.enabled) }.padding(12).background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
                if model.reportHTML != nil {
                    HStack { Button("Open Report", action: model.openReport); Button { model.revealReport() } label: { Image(systemName: "folder") }.help("Show reports in Finder").disabled(model.reportURLs.isEmpty) }
                }
                Text("Copies regular file contents. Empty folders, links, Finder tags, and some other metadata are not included. Sources containing links are rejected.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(22)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var statusBar: some View {
        HStack(spacing: 18) {
            ZStack { Circle().fill(.purple.opacity(0.12)).frame(width: 36, height: 36); Image(systemName: model.hasActiveWork ? "arrow.triangle.2.circlepath" : model.fraction == 1 ? "checkmark" : "folder").foregroundStyle(.purple) }
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(model.phase).font(.callout.weight(.medium)); if model.hasActiveWork { Text("\(Int(model.fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }
                if model.hasActiveWork { ProgressView(value: model.fraction).progressViewStyle(.linear).frame(maxWidth: 440) }
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.hasActiveWork {
                Button("Transfer Queue") { model.showingQueue = true }.keyboardShortcut("j")
                Button(model.queueRunning ? "Pause Queue" : "Stop", action: model.stop).keyboardShortcut(".")
            } else {
                Button(model.inspected ? "Review Again" : "Review Copy", action: model.reviewCopy)
                    .disabled(!model.canReview).help("Optional: hash sources and preview conflicts before copying")
                Button("Add to Queue", action: model.queueCopy).disabled(!model.canStart)
                Button(action: model.startCopy) { Label("Start Copy", systemImage: "play.fill").frame(minWidth: 110) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
            }
        }.padding(.horizontal, 24).padding(.vertical, 17)
    }

    private func destination(_ title: String, subtitle: String, icon: String, url: URL?, index: Int) -> some View {
        Button { model.chooseDestination(replacing: index) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(.purple).frame(width: 27).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(url?.lastPathComponent ?? "Choose a folder…").font(.caption).foregroundStyle(url == nil ? .purple : .secondary).lineLimit(1)
                    if let url {
                        Text(url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(url.path)
                        if let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
                            Text("\(bytes(Int64(capacity))) available").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    else { Text(subtitle).font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
        }.buttonStyle(.plain).disabled(model.hasActiveWork)
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct ReportPreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.loadHTMLString(html, baseURL: nil)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { if context.coordinator.html != html { context.coordinator.html = html; view.loadHTMLString(html, baseURL: nil) } }
    final class Coordinator { var html = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
}

private struct CopyToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(nsColor: .controlColor).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            .padding(.horizontal, 4)
    }
}
