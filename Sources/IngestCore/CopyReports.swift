import Foundation

public enum CopyReports {
    public static var appFolder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OKCopy/Reports") }
    static func save(plan: BatchPlan, name: String, html: String, json: Data, project: Directory) throws -> URL {
        if plan.settings.reportsLocation == .destination {
            try project.writeNew("Ingest Reports/" + name + ".html", data: Data(html.utf8))
            try project.writeNew("Ingest Reports/" + name + ".json", data: json)
            return try project.actualURL().appendingPathComponent("Ingest Reports/" + name + ".html")
        }
        let root = plan.settings.reportsLocation == .folder ? plan.settings.reportFolder : appFolder
        guard let root else { throw IngestError("Choose a report folder before copying") }
        let actual = root.standardizedFileURL.resolvingSymlinksInPath()
        for source in plan.sources where Planner.overlap(actual, source.snapshot.protectedRoot) { throw IngestError("Report storage overlaps a protected source") }
        // App reports may be created; custom exports require an existing chosen folder.
        if plan.settings.reportsLocation == .app { try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true) }
        let folder = try Directory(url: actual)
        let anchored = try folder.actualURL()
        for source in plan.sources where Planner.overlap(anchored, source.snapshot.protectedRoot) { throw IngestError("Report folder moved into a source") }
        let unique = name + "-" + UUID().uuidString
        try folder.writeNew(unique + ".html", data: Data(html.utf8))
        try folder.writeNew(unique + ".json", data: json)
        return anchored.appendingPathComponent(unique + ".html")
    }
}
