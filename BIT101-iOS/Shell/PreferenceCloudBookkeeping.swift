import Foundation
import StorageCore

extension ExperimentalPreferenceCloudSync {
    func nextLocalUpdatedAt(
        for domain: ExperimentalPreferenceSyncDomain,
        remoteUpdatedAt: Date? = nil, owner: AppStorageSession? = nil
    ) -> Date {
        var updatedAt = Date()
        if let localUpdatedAt = localUpdatedAt(for: domain, owner: owner),
            updatedAt <= localUpdatedAt
        {
            updatedAt = laterDate(after: localUpdatedAt)
        }
        if let remoteUpdatedAt, updatedAt <= remoteUpdatedAt {
            updatedAt = laterDate(after: remoteUpdatedAt)
        }
        return updatedAt
    }

    func laterDate(after date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextUp)
    }

    var enabledKey: String {
        "experimental.preference-cloud-sync.enabled.\(localAccountIdentifier)"
    }

    var legacyEnabledKey: String {
        "experimental.preference-cloud-sync.enabled.\(accountIdentifier)"
    }

    func localUpdatedAtKey(
        for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil
    ) -> String {
        """
        experimental.preference-cloud-sync.local-updated.\
        \(owner?.accountStorageIdentifier ?? localAccountIdentifier).\(domain.rawValue)
        """
    }

    func legacyLocalUpdatedAtKey(
        for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil
    ) -> String {
        """
        experimental.preference-cloud-sync.local-updated.\
        \(owner?.accountDirectoryName ?? accountIdentifier).\(domain.rawValue)
        """
    }

    func cloudKey(for domain: ExperimentalPreferenceSyncDomain) -> String {
        "preference-sync.v2.\(accountIdentifier).\(domain.rawValue)"
    }

    func cloudKeys(for domain: ExperimentalPreferenceSyncDomain) -> [String] {
        [cloudKey(for: domain), "preference-sync.v1.\(accountIdentifier).\(domain.rawValue)"]
    }

    var accountIdentifier: String {
        stores.currentSession().accountDirectoryName
    }

    var localAccountIdentifier: String {
        stores.currentSession().accountStorageIdentifier
    }

    func loadEnabledPreference() -> Bool {
        if let value = defaults.object(forKey: enabledKey) as? Bool { return value }
        guard let legacyValue = defaults.object(forKey: legacyEnabledKey) as? Bool else {
            return false
        }
        defaults.set(legacyValue, forKey: enabledKey)
        if legacyEnabledKey != enabledKey { defaults.removeObject(forKey: legacyEnabledKey) }
        return legacyValue
    }

    func localUpdatedAt(
        for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil
    ) -> Date? {
        if let value = defaults.object(forKey: localUpdatedAtKey(for: domain, owner: owner))
            as? Date
        {
            return value
        }
        let legacyKey = legacyLocalUpdatedAtKey(for: domain, owner: owner)
        guard let value = defaults.object(forKey: legacyKey) as? Date else { return nil }
        defaults.set(value, forKey: localUpdatedAtKey(for: domain, owner: owner))
        defaults.removeObject(forKey: legacyKey)
        return value
    }

    func setLocalUpdatedAt(
        _ value: Date, for domain: ExperimentalPreferenceSyncDomain, owner: AppStorageSession? = nil
    ) {
        defaults.set(value, forKey: localUpdatedAtKey(for: domain, owner: owner))
        if legacyLocalUpdatedAtKey(for: domain, owner: owner)
            != localUpdatedAtKey(for: domain, owner: owner)
        {
            defaults.removeObject(forKey: legacyLocalUpdatedAtKey(for: domain, owner: owner))
        }
    }
}
