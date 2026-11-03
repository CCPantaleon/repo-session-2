import Foundation

enum Report {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    static func html(plan: IngestPlan, records: [FileVerification], status: String, detail: String) -> String {
        let rows = records.map { record in
            "<tr><td>\(escape(record.path))<small>\(record.bytes) bytes</small></td><td class='hash'>\(record.sourceSHA256 ?? "—")</td><td class='hash'>\(record.workingSHA256 ?? "—")</td><td class='hash'>\(record.backupSHA256 ?? (plan.backupProject == nil ? "Not selected" : "—"))</td><td>\(escape(record.status))</td></tr>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'">
        <title>OK, Copy · \(escape(plan.request.projectName))</title><style>
        :root{color-scheme:light dark}*{box-sizing:border-box}body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.55;margin:0;padding:48px;color:#21302f;background:#f6f7f3}main{max-width:1400px;margin:auto}h1{font-size:36px;letter-spacing:-1px;margin:8px 0}h2{font-size:20px;margin-top:36px}.eyebrow{color:#316e62;font-size:12px;letter-spacing:3px;font-weight:700}.status{display:inline-block;padding:6px 12px;border:1px solid #b7ccc2;border-radius:20px;background:#e4eee6;font-weight:600}.details{display:grid;grid-template-columns:160px 1fr;gap:10px;margin:28px 0;padding:24px;background:#fff;border-radius:14px;overflow-wrap:anywhere}dt{color:#66746e}dd{margin:0}table{width:100%;border-collapse:collapse;background:#fff;font-size:12px}th{text-align:left;background:#e8eee8}td,th{padding:14px;border-bottom:1px solid #e2e7e2;vertical-align:top}td{overflow-wrap:anywhere}.hash{font:10px ui-monospace,monospace;word-break:break-all;max-width:220px}small{display:block;color:#6b756f}footer{margin-top:28px;color:#66746e;font-size:12px}.scroll{overflow:auto}@media(prefers-color-scheme:dark){body{background:#19201e;color:#e2e9e4}.details,table{background:#222c27}th{background:#303c35}td,th{border-color:#39463d}.status{background:#293e34;border-color:#496a57}.eyebrow,small,dt,footer{color:#a1b8a9}}@media print{body{padding:16px;background:white;color:black}.details,table{background:white}.hash{font-size:8px}}
        </style></head><body><main><div class="eyebrow">OK, COPY / VERIFIED INGEST</div><h1>\(escape(plan.request.projectName))</h1>
        <p class="status">\(escape(status))</p><p>\(escape(detail))</p><dl class="details">
        <dt>Generated</dt><dd>\(escape(Date().formatted(date: .abbreviated, time: .standard)))</dd>
        <dt>Source · read only</dt><dd>\(escape(plan.request.snapshot.root.path))</dd>
        <dt>Working project</dt><dd>\(escape(plan.workingProject.path))</dd><dt>Backup project</dt><dd>\(escape(plan.backupProject?.path ?? "Not selected · no backup created"))</dd>
        <dt>Selected copies</dt><dd>\(plan.destinationProjects.count) per original</dd><dt>Advisory</dt><dd>\(escape(plan.warnings.joined(separator: " ")))</dd><dt>Inventory</dt><dd>\(plan.request.snapshot.files.count) files · \(plan.totalBytes) bytes per destination · \(records.filter { $0.status == "Verified" }.count) verified</dd>
        <dt>Folder convention</dt><dd>\(escape(plan.folderName))/Originals/\(escape(plan.cardName))/[original relative path]</dd>
        </dl><h2>File checksums · SHA-256</h2><div class="scroll"><table><thead><tr><th>Original file</th><th>Source</th><th>Working copy</th><th>Backup copy</th><th>Result</th></tr></thead><tbody>\(rows)</tbody></table></div>
        <footer>OK, Copy 1.1 · Data-fork contents are verified. Original relative paths and modification times are preserved. Finder tags, extended attributes, resource forks, and empty directories are not copied. No source file was intentionally written, renamed, or removed. This report is a local receipt, not a signed certificate.</footer></main></body></html>
        """
    }
    static func manifest(plan: IngestPlan, records: [FileVerification], status: String) throws -> Data {
        struct Manifest: Encodable {
            let schemaVersion = 1
            let algorithm = "SHA-256"
            let status: String
            let project: String
            let source: String
            let generatedAt: Date
            let backupSelected: Bool
            let destinationCount: Int
            let advisories: [String]
            let files: [FileVerification]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Manifest(status: status, project: plan.folderName, source: plan.request.snapshot.root.path, generatedAt: Date(), backupSelected: plan.backupProject != nil, destinationCount: plan.destinationProjects.count, advisories: plan.warnings, files: records))
    }
}
