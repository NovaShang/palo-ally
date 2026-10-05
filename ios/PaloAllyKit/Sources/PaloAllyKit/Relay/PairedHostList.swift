import Foundation

extension PairedHost: Identifiable {
    /// A computer is identified by its daemon id (its relay identity).
    public var id: String { daemonID }
}

/// The computers this device is paired with, in the owner's order. Each one
/// is an independent assistant; the app connects to all of them. Kept in the
/// Keychain as one JSON array. Older builds stored a single `paired-host`
/// item; it becomes the first entry on first load (no re-pairing).
public enum PairedHostList {
    static let account = "paired-hosts"

    public static func load(from store: SecretStore) -> [PairedHost] {
        if let data = try? store.load(account) {
            return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
        }
        guard let legacy = PairedHost.load(from: store) else { return [] }
        let list = [legacy]
        // Only drop the old item once the list is safely written.
        if (try? save(list, to: store)) != nil { PairedHost.forget(in: store) }
        return list
    }

    /// Saves the list (an empty list is saved too, so nothing re-migrates).
    public static func save(_ hosts: [PairedHost], to store: SecretStore) throws {
        try store.save(JSONEncoder().encode(hosts), for: account)
    }

    /// Adds a newly paired computer at the end; re-pairing the same computer
    /// replaces it in place.
    public static func upsert(_ host: PairedHost, into hosts: [PairedHost]) -> [PairedHost] {
        var list = hosts
        if let i = list.firstIndex(where: { $0.daemonID == host.daemonID }) {
            list[i] = host
        } else {
            list.append(host)
        }
        return list
    }
}
