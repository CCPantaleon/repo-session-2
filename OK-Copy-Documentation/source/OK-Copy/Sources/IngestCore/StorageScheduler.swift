import Foundation
import Darwin
import DiskArbitration
import IOKit

struct StorageLocation: Sendable {
    let keys: [String]
    let description: String
}

/// Read-only discovery. Unknown topology is grouped conservatively by filesystem.
final class StorageScheduler: @unchecked Sendable {
    private var locations: [String: StorageLocation] = [:]
    private var locks: [String: NSLock] = [:]
    init(urls: [URL], discover: (URL) -> StorageLocation = StorageScheduler.discover) {
        for url in urls {
            let location = discover(url)
            locations[url.path] = location
            for key in location.keys where locks[key] == nil { locks[key] = NSLock() }
        }
    }
    func location(_ url: URL) -> StorageLocation { locations[url.path] ?? StorageLocation(keys: ["unknown"], description: "Topology unavailable") }
    func access<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let held = location(url).keys.sorted().compactMap { locks[$0] }
        held.forEach { $0.lock() }; defer { held.reversed().forEach { $0.unlock() } }
        return try body()
    }
    static func discover(_ url: URL) -> StorageLocation {
        let device = (try? Directory(url: url).stamp().device) ?? 0
        var keys = ["filesystem:\(device)"]
        var description = "Filesystem grouping · hardware topology unavailable"
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL) else { return StorageLocation(keys: keys, description: description) }
        if let whole = DADiskCopyWholeDisk(disk), let bsd = DADiskGetBSDName(whole) {
            keys.append("disk:" + String(cString: bsd)); description = "Disk " + String(cString: bsd)
        }
        let media = DADiskCopyIOMedia(disk)
        if media != 0 {
            var entry = media
            for step in 0..<32 {
                if IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0 {
                    var id: UInt64 = 0
                    if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { keys.append("physical:\(id)"); description += " · physical storage grouped" }
                }
                if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                    var id: UInt64 = 0
                    if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { keys.append("usb:\(id)"); description += " · shared USB ancestry grouped" }
                }
                var parent: io_registry_entry_t = 0
                let found = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
                IOObjectRelease(entry)
                guard found == KERN_SUCCESS else { break }
                entry = parent
                if step == 31 { IOObjectRelease(entry) }
            }
        }
        return StorageLocation(keys: Array(Set(keys)), description: description)
    }
}
