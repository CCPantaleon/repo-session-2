import Foundation
import Darwin

struct PendingReport: Codable {
    let name: String
    let html: String
    let json: Data
}

extension TransferEngine {
    /// Re-export the frozen receipt; this does not certify a fresh readback of current files.
    public static func retryReports(_ job: TransferJob) throws -> [URL] {
        var reports: [URL] = []
        var failures: [String] = []
        for identity in job.plan.destinations {
            do {
                try BatchPlanner.validateLocations(sources: job.plan.sources, destinations: [identity])
                try identity.validate(Directory(url: identity.root))
                let project = try Directory(url: job.plan.projectURL(identity))
                let workspace = try project.child(".OKCopy").child("Jobs").child(job.id.uuidString)
                guard workspace.exists("PendingReport.json") else { continue }
                guard try workspace.smallData("Owner") == Data(job.id.uuidString.utf8) else { throw IngestError("Recovery workspace belongs to a different job") }
                let owner = try workspace.readFile("Owner"); defer { close(owner) }
                guard flock(owner, LOCK_EX | LOCK_NB) == 0 else { throw IngestError("This job is active in another process") }
                let input = try workspace.readFile("PendingReport.json"); defer { close(input) }
                guard try fileSize(input) <= 128 * 1024 * 1024 else { throw IngestError("Recovery receipt exceeds 128 MiB") }
                var data = Data(); _ = try stream(input, token: CancellationToken()) { data.append($0) }
                let payload = try JSONDecoder().decode(PendingReport.self, from: data)
                let report = try CopyReports.save(plan: job.plan, name: "Recovered-" + UUID().uuidString, html: payload.html, json: payload.json, project: project)
                reports.append(report)
                guard unlinkat(workspace.fd, "PendingReport.json", 0) == 0 else { throw systemError("Could not retire report recovery record") }
                _ = fsync(workspace.fd)
            } catch { failures.append(identity.root.path + ": " + error.localizedDescription) }
        }
        if !failures.isEmpty { throw IngestError(failures.joined(separator: "\n"), reports: reports) }
        return reports
    }
}
