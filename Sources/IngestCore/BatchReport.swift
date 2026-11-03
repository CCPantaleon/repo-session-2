import Foundation

public enum BatchReport {
    public static func dryRun(_ plan: BatchPlan) -> String {
        let rows = plan.files.map { file in
            "<tr><td>\(Report.escape(file.outputPath))</td><td>\(file.original.bytes)</td><td class='hash'>\(file.sha256)</td><td>\(Report.escape(file.duplicateOf.map { "Identical content: " + $0 } ?? "Unique content"))</td></tr>"
        }.joined()
        let table = "<table><tr><th>Planned path</th><th>Bytes</th><th>Source SHA-256</th><th>Duplicate detection</th></tr>\(rows)</table>"
        return page(plan: plan, title: "Dry run complete", detail: "No destination files were created or changed. \(plan.settings.cascade ? "Cascading: destination 1 is verified before backups begin." : "Direct copying: independent bounded destination writers.") Up to \(plan.settings.concurrentSources) source workers; shared discovered hardware is grouped. MHL export \(plan.settings.manifests ? "on" : "off"). \(plan.existingCopies) existing copies matched their source SHA-256 and can be skipped after reverification. \(plan.duplicateCount) duplicate-content source files detected; every original path will be retained.", table: table)
    }
    static func html(_ plan: BatchPlan, records: [CopyReceipt], status: String, detail: String) -> String {
        let verifiedRows = records.flatMap { file in
            file.destinations.map { dest in
                "<tr><td>\(Report.escape(file.outputPath))<small>\(file.bytes) bytes</small></td><td>\(Report.escape(dest.root.path))</td><td class='hash'>\(file.sourceSHA256)</td><td class='hash'>\(dest.sha256)</td><td class='success'>\(Report.escape(dest.action))<small>\(dest.resumedBytes) resumed bytes</small></td></tr>"
            }
        }.joined()
        let missingRows = plan.files.flatMap { file in
            plan.destinations.compactMap { destination -> String? in
                if records.contains(where: { $0.outputPath == file.outputPath && $0.destinations.contains(where: { $0.root == destination.root }) }) { return nil }
                return "<tr><td>\(Report.escape(file.outputPath))</td><td>\(Report.escape(destination.root.path))</td><td>—</td><td>—</td><td class='failure'>Not verified</td></tr>"
            }
        }.joined()
        let rows = verifiedRows + missingRows
        return page(plan: plan, title: status, detail: detail, table: "<table><tr><th>Original path</th><th>Destination</th><th>Source SHA-256</th><th>Destination SHA-256</th><th>Result</th></tr>\(rows)</table>")
    }
    static func json(_ plan: BatchPlan, jobID: UUID, records: [CopyReceipt], status: String) throws -> Data {
        struct Manifest: Encodable {
            let schemaVersion = 2
            let app = "OK, Copy " + AppVersion.current
            let algorithm = "SHA-256"
            let jobID: UUID
            let status: String
            let plan: BatchPlan
            let files: [CopyReceipt]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Manifest(jobID: jobID, status: status, plan: plan, files: records))
    }
    private static func page(plan: BatchPlan, title: String, detail: String, table: String) -> String {
        let sourceList = plan.sources.map { Report.escape($0.label + " · " + $0.snapshot.root.path) }.joined(separator: "<br>")
        let outcomeClass = title.lowercased().contains("verified") && !title.lowercased().contains("incomplete") ? "success" : title.lowercased().contains("incomplete") || title.lowercased().contains("fail") ? "failure" : ""
        let targets = plan.destinations.map { Report.escape(plan.projectURL($0).path) }.joined(separator: "<br>")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>OK, Copy · \(Report.escape(plan.projectName))</title><style>
        :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;padding:40px;font:14px -apple-system,BlinkMacSystemFont,sans-serif;background:#f7f4fa;color:#30243c;line-height:1.55}main{max-width:1400px;margin:auto}h1{font-size:34px;letter-spacing:-1px}h2{font-size:20px}.eyebrow{font-size:11px;letter-spacing:3px;color:#7950a1;font-weight:700}.badge{display:inline-block;padding:6px 12px;border-radius:20px;background:#ece1f6}.details{padding:22px;background:#fff;border-radius:14px;overflow-wrap:anywhere}dt{font-weight:600;margin-top:12px}dd{margin:4px 0;color:#6e607c}table{width:100%;border-collapse:collapse;background:#fff;font-size:12px}th,td{padding:12px;text-align:left;vertical-align:top;border-bottom:1px solid #e3d9ec;overflow-wrap:anywhere}th{background:#ece4f4}.hash{font:10px ui-monospace,monospace;word-break:break-all;min-width:110px}small{display:block;color:#81728e}.scroll{overflow:auto}footer{font-size:11px;color:#81728e;margin-top:30px}@media(prefers-color-scheme:dark){body{background:#21182b;color:#ede4f5}.details,table{background:#30233d}th,.badge{background:#4c365e}td,th{border-color:#604a73}dd,small,footer{color:#c6b3d5}.eyebrow{color:#c7a6e0}}
         .badge.success{background:#ddf4e3}.badge.failure{background:#fbe3e3}.success{color:#147a36!important}.failure{color:#c82828!important}@media(prefers-color-scheme:dark){.badge.success{background:#173d2b}.badge.failure{background:#4b1d22}.success{color:#76e09a!important}.failure{color:#ff8989!important}}</style></head><body><main><div class="eyebrow">OK, COPY / VERIFIED COPYING TOOL</div><h1>\(Report.escape(plan.projectName))</h1><h2 class="badge \(outcomeClass)">\(Report.escape(title))</h2><p>\(Report.escape(detail))</p><dl class="details"><dt>Sources · read only</dt><dd>\(sourceList)</dd><dt>Destination projects</dt><dd>\(targets)</dd><dt>Plan</dt><dd>\(plan.files.count) files · \(plan.totalBytes) bytes per destination · Incremental \(plan.incremental ? "on" : "off")</dd><dt>Advisories</dt><dd>\(Report.escape(plan.warnings.joined(separator: " ")))</dd><dt>Generated</dt><dd>\(Report.escape(Date().formatted()))</dd></dl><h2>File verification</h2><div class="scroll">\(table)</div><footer>OK, Copy \(AppVersion.current) · Existing matching files are independently rehashed before skipping. Identical content at distinct source paths is retained. Checkpoints do not substitute for verification. Source cards are never written, deleted, repaired, or formatted. SHA-256 covers data forks; extended attributes, resource forks, and empty directories are not copied. A successful copy does not certify media validity or card health.</footer></main></body></html>
        """
    }
}
