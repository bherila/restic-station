import Foundation
import ResticStationCore

/// Everything the Backup Sets screens (T14) need from `AppModel` that is not
/// already part of the shell it inherited from T13: set/destination
/// persistence, the keychain items a destination owns, the on-demand repo
/// probe, and repository initialization.
///
/// It lives in its own file — not in `AppModel.swift` — so the shell stays
/// owned by T13 and this surface stays reviewable on its own.
///
/// Every write still goes through `AppModel.saveConfig(_:)`, which validates
/// before it touches disk; nothing here bypasses it.
extension AppModel {

    struct DestinationSecretsRollback: Sendable {
        let transaction: DestinationSecretRollback
        let sequence: UInt64

        var destId: UUID { transaction.destId }

        init(transaction: DestinationSecretRollback, sequence: UInt64 = 0) {
            self.transaction = transaction
            self.sequence = sequence
        }
    }

    // MARK: - Collaborators

    /// The secret store this app writes destination passwords into — the
    /// same one the helper reads (`docs/keychain-and-fda.md`): the login
    /// keychain by default, or `secrets.json` when
    /// `RESTIC_STATION_SECRET_BACKEND=file`. Cheap to build.
    ///
    /// **The helper path is not this process.** With the file backend the
    /// store bakes an executable into `RESTIC_PASSWORD_COMMAND`, and restic
    /// runs it as a child to read the password. Naming the app binary there
    /// would hand restic a SwiftUI app that cannot print a password and
    /// would try to open a UI, so every app-side store names the *embedded
    /// helper* — the same binary `HelperInvoker` and the LaunchAgent use.
    /// The factory requires this explicitly, so a new app-side call site
    /// cannot forget it.
    ///
    /// Throws only when the `RESTIC_STATION_SECRET_BACKEND` override is
    /// unrecognised — deliberately a hard error rather than a silent
    /// fallback to the wrong store.
    func makeSecretStore() throws -> any SecretStore {
        try secretStoreFactory()
    }

    /// `makeSecretStore()` for the call sites that can only degrade (reading
    /// back a password to pre-fill an editor, deleting a destination's
    /// secrets). Every site that can *report* the failure calls the throwing
    /// form instead.
    var secrets: (any SecretStore)? {
        try? makeSecretStore()
    }

    // MARK: - Sets

    /// Inserts or replaces `set` and saves. Throws `ConfigError` when the
    /// resulting config is invalid, which the editor maps to an inline field
    /// message.
    @discardableResult
    func saveSet(
        _ set: BackupSet,
        ifUnchangedFrom expectedFingerprint: String? = nil
    ) throws -> String {
        var draft = config
        if let index = draft.sets.firstIndex(where: { $0.id == set.id }) {
            draft.sets[index] = set
        } else {
            draft.sets.append(set)
        }
        return try saveConfig(draft, ifUnchangedFrom: expectedFingerprint)
    }

    /// Deletes a set's configuration. Per the confirmation copy
    /// (`docs/ui-spec.md`: "Deletes the backup set configuration.
    /// Repositories and snapshots are NOT touched.") this touches neither the
    /// repositories nor the keychain items of its destinations: the copy does
    /// not promise password deletion, and a deleted repository password is
    /// unrecoverable. Removing a *destination* does delete them — that
    /// confirmation says so explicitly.
    func deleteSet(id: UUID) throws {
        var draft = config
        draft.sets.removeAll { $0.id == id }
        try saveConfig(draft)
    }

    /// A blank set with the defaults `docs/data-model.md` documents: daily
    /// 02:30, 14-day staleness warning, no retention, no scheduled checks.
    func newSetTemplate() -> BackupSet {
        BackupSet(
            id: UUID(),
            name: defaultSetName(),
            sources: [],
            excludes: [],
            schedule: .daily(hour: 2, minute: 30),
            retention: nil,
            checkPolicy: nil,
            stalenessWarningDays: 14,
            destinations: []
        )
    }

    private func defaultSetName() -> String {
        let existing = Set(config.sets.map(\.name))
        if !existing.contains("Backup Set") {
            return "Backup Set"
        }
        var index = 2
        while existing.contains("Backup Set \(index)") {
            index += 1
        }
        return "Backup Set \(index)"
    }

    // MARK: - Destination state

    func repoStatus(destId: UUID) -> RepoStatus? {
        stateWatcher.repoStatuses[destId]
    }

    func isDestinationStale(setId: UUID, destId: UUID) -> Bool {
        setHealth(for: setId)?.staleDestinationIds.contains(destId) ?? false
    }

    func destinationStatus(setId: UUID, destId: UUID) -> DestinationStatus {
        DestinationStatus.derive(
            status: repoStatus(destId: destId),
            isStale: isDestinationStale(setId: setId, destId: destId)
        )
    }

    // MARK: - Destination secrets

    /// Writes a destination's keychain items (`docs/data-model.md` §Keychain
    /// items). A `nil` argument means "leave what is there alone": an empty
    /// password field on an existing destination keeps the stored password
    /// rather than clobbering it.
    @discardableResult
    func storeDestinationSecrets(
        destId: UUID,
        password: String?,
        secretEnv: [String: String]?,
        ifConfigUnchangedFrom expectedFingerprint: String,
        editorSessionId: UUID? = nil
    ) async throws -> DestinationSecretsRollback {
        if let configLoadError {
            throw AppModelError.configUnreadable(configLoadError)
        }
        // A retry that was already running when this editor opened owns the
        // older side of the credential chain. Let it finish before the newer
        // mutation can compete for secrets.lock; retries that have not yet
        // started are held by activeSecretEditorSessions below.
        if let pendingSecretRollbackTask {
            await pendingSecretRollbackTask.value
        }
        let store = try makeSecretStore()
        var rollback: DestinationSecretsRollback?
        do {
            let snapshot = try await configStore.withUnchangedRevision(from: expectedFingerprint) {
                let transaction = try await store.updateDestinationSecrets(
                    DestinationSecretUpdate(
                        destId: destId,
                        password: password?.isEmpty == false ? password : nil,
                        secretEnv: secretEnv
                    )
                )
                nextSecretRollbackSequence &+= 1
                let snapshot = DestinationSecretsRollback(
                    transaction: transaction,
                    sequence: nextSecretRollbackSequence
                )
                rollback = snapshot
                return snapshot
            }
            if let editorSessionId {
                parkEditorSecretRollback(snapshot, sessionId: editorSessionId)
            }
            return snapshot
        } catch {
            if let rollback {
                var remaining = [rollback]
                do {
                    _ = try await restoreDestinationSecrets(
                        [rollback],
                        using: store,
                        onProgress: { remaining = $0 }
                    )
                } catch let rollbackError {
                    retainPendingSecretRollbacks(remaining)
                    throw AppModelError.secretRollbackFailed(
                        original: "\(error)", rollback: "\(rollbackError)"
                    )
                }
            }
            if let storeError = error as? ConfigStoreError,
               storeError.isRevisionConflict {
                noteConfigChangedOnDisk()
            }
            throw error
        }
    }

    func beginSecretEditorSession(_ sessionId: UUID) {
        activeSecretEditorSessions.insert(sessionId)
    }

    func endSecretEditorSession(
        _ sessionId: UUID,
        claimedRollbacks: [DestinationSecretsRollback] = []
    ) {
        activeSecretEditorSessions.remove(sessionId)
        claimedSecretEditorRollbacks.removeValue(forKey: sessionId)
        // Keep claimed and still-parked mutations together for ownership;
        // each token's global sequence, not this array's insertion order,
        // determines the eventual rollback order.
        let stranded = unclaimedSecretEditorRollbacks.removeValue(forKey: sessionId) ?? []
        retainPendingSecretRollbacks(claimedRollbacks + stranded)
        // A queued abandoned-session rollback is deliberately paused while
        // any editor can still produce a newer rollback. Resume it once the
        // last editor has synchronously transferred its ownership here.
        retryPendingSecretRollbacks()
    }

    /// Claims the rollback parked before an async keychain write returned to
    /// SwiftUI. Main-actor serialization makes claim + local append atomic
    /// with respect to the parent editor's `onDisappear`.
    func claimEditorSecretRollback(
        _ rollback: DestinationSecretsRollback,
        sessionId: UUID
    ) -> Bool {
        guard activeSecretEditorSessions.contains(sessionId),
              var parked = unclaimedSecretEditorRollbacks[sessionId],
              let index = parked.firstIndex(where: { $0.sequence == rollback.sequence }) else {
            return false
        }
        parked.remove(at: index)
        if parked.isEmpty {
            unclaimedSecretEditorRollbacks.removeValue(forKey: sessionId)
        } else {
            unclaimedSecretEditorRollbacks[sessionId] = parked
        }
        claimedSecretEditorRollbacks[sessionId, default: []].append(rollback)
        return true
    }

    private func parkEditorSecretRollback(
        _ rollback: DestinationSecretsRollback,
        sessionId: UUID
    ) {
        guard activeSecretEditorSessions.contains(sessionId) else {
            retainPendingSecretRollbacks([rollback])
            return
        }
        unclaimedSecretEditorRollbacks[sessionId, default: []].append(rollback)
    }

    /// Restores the exact fields the editor changed when the subsequent
    /// config CAS refuses. Fields the editor left alone are not touched.
    @discardableResult
    func restoreDestinationSecrets(
        _ rollback: DestinationSecretsRollback,
        editorSessionId: UUID? = nil
    ) async throws -> Bool {
        var remaining = [rollback]
        do {
            return try await restoreDestinationSecrets(
                [rollback],
                editorSessionId: editorSessionId,
                onProgress: { remaining = $0 }
            )
        } catch {
            if let editorSessionId {
                removeClaimedSecretRollbacks(
                    withSequences: Set(remaining.map(\.sequence)),
                    sessionId: editorSessionId
                )
            }
            retainPendingSecretRollbacks(remaining)
            throw error
        }
    }

    /// Rolls a sequence of edits back in reverse order. Editing the same
    /// destination twice produces a chain of snapshots, so restoring in
    /// insertion order would stop at the value installed by the first edit
    /// instead of returning to the value that preceded the editor session.
    @discardableResult
    func restoreDestinationSecrets(
        _ rollbacks: [DestinationSecretsRollback],
        editorSessionId: UUID? = nil,
        onProgress: (([DestinationSecretsRollback]) -> Void)? = nil
    ) async throws -> Bool {
        if let editorSessionId {
            if let pendingSecretRollbackTask {
                await pendingSecretRollbackTask.value
            }
            // Do not consume an intermediate queued link while an even newer
            // live editor still owns the installed value. That editor must
            // restore first or the queued chain would be misclassified as an
            // external conflict and discarded.
            if hasNewerLiveSecretRollback(than: rollbacks, excluding: editorSessionId) {
                throw AppModelError.newerSecretEditorMutation
            }
            try await drainQueuedSecretRollbacks(newerThan: rollbacks)
            if hasNewerLiveSecretRollback(than: rollbacks, excluding: editorSessionId) {
                throw AppModelError.newerSecretEditorMutation
            }
        }
        let store = try makeSecretStore()
        return try await restoreDestinationSecrets(
            rollbacks,
            using: store,
            onProgress: { progress in
                if let editorSessionId {
                    self.replaceClaimedSecretRollbacks(
                        rollbacks,
                        with: progress,
                        sessionId: editorSessionId
                    )
                }
                onProgress?(progress)
            }
        )
    }

    private func hasNewerLiveSecretRollback(
        than rollbacks: [DestinationSecretsRollback],
        excluding sessionId: UUID
    ) -> Bool {
        let requested = rollbacks.compactMap(rollbackWithUncommittedFields)
        guard !requested.isEmpty else { return false }
        let otherSessions = activeSecretEditorSessions.subtracting([sessionId])
        let live = otherSessions.flatMap { otherSession in
            (claimedSecretEditorRollbacks[otherSession] ?? [])
                + (unclaimedSecretEditorRollbacks[otherSession] ?? [])
        }.compactMap(rollbackWithUncommittedFields)

        return requested.contains { older in
            live.contains { newer in
                guard newer.destId == older.destId,
                      newer.sequence > older.sequence else { return false }
                let overlapsPassword = older.transaction.password != nil
                    && newer.transaction.password != nil
                let overlapsSecretEnv = older.transaction.secretEnv != nil
                    && newer.transaction.secretEnv != nil
                return overlapsPassword || overlapsSecretEnv
            }
        }
    }

    /// An explicit Revert remains usable when a newer editor has already
    /// closed. Drain the causally newer queued transitions first, one global
    /// sequence at a time, then let the caller restore its older view-owned
    /// chain. The current editor stays active so unrelated background retry
    /// work remains paused.
    private func drainQueuedSecretRollbacks(
        newerThan requestedRollbacks: [DestinationSecretsRollback]
    ) async throws {
        let requested = requestedRollbacks.compactMap(rollbackWithUncommittedFields)
        guard !requested.isEmpty else { return }

        while let queued = pendingSecretRollbackBatches
            .flatMap({ $0 })
            .compactMap(rollbackWithUncommittedFields)
            .filter({ newer in
                requested.contains { older in
                    guard newer.destId == older.destId,
                          newer.sequence > older.sequence else { return false }
                    return (newer.transaction.password != nil && older.transaction.password != nil)
                        || (newer.transaction.secretEnv != nil && older.transaction.secretEnv != nil)
                }
            })
            .max(by: { $0.sequence < $1.sequence }) {
            removePendingSecretRollback(sequence: queued.sequence)
            var remaining = [queued]
            do {
                _ = try await restoreDestinationSecrets(
                    [queued],
                    onProgress: { remaining = $0 }
                )
            } catch {
                pendingSecretRollbackBatches.append(remaining)
                pendingSecretRollbackError =
                    "Some destination credentials could not be restored (\(error)). "
                    + "Backups may use credentials from an abandoned edit until restoration succeeds."
                throw error
            }
        }
        if pendingSecretRollbackBatches.isEmpty {
            pendingSecretRollbackError = nil
        }
    }

    private func removePendingSecretRollback(sequence: UInt64) {
        pendingSecretRollbackBatches = pendingSecretRollbackBatches.compactMap { batch in
            let remaining = batch.filter { $0.sequence != sequence }
            return remaining.isEmpty ? nil : remaining
        }
    }

    private func replaceClaimedSecretRollbacks(
        _ originals: [DestinationSecretsRollback],
        with progress: [DestinationSecretsRollback],
        sessionId: UUID
    ) {
        let sequences = Set(originals.map(\.sequence))
        removeClaimedSecretRollbacks(withSequences: sequences, sessionId: sessionId)
        guard !progress.isEmpty else { return }
        claimedSecretEditorRollbacks[sessionId, default: []].append(contentsOf: progress)
    }

    private func removeClaimedSecretRollbacks(
        withSequences sequences: Set<UInt64>,
        sessionId: UUID
    ) {
        guard var claimed = claimedSecretEditorRollbacks[sessionId] else { return }
        claimed.removeAll { sequences.contains($0.sequence) }
        if claimed.isEmpty {
            claimedSecretEditorRollbacks.removeValue(forKey: sessionId)
        } else {
            claimedSecretEditorRollbacks[sessionId] = claimed
        }
    }

    /// Restores one field at a time and publishes the remaining tokens after
    /// every completed field. Keychain operations cannot atomically update
    /// two separate items; this checkpoint makes a retry continue with only
    /// the field that failed instead of misclassifying the already-restored
    /// field as an external conflict and abandoning its older rollback chain.
    private func restoreDestinationSecrets(
        _ rollbacks: [DestinationSecretsRollback],
        using store: any SecretStore,
        onProgress: (([DestinationSecretsRollback]) -> Void)? = nil
    ) async throws -> Bool {
        let eligibleRollbacks = rollbacks.compactMap(rollbackWithUncommittedFields)
        onProgress?(eligibleRollbacks)
        var remaining = eligibleRollbacks.map(\.transaction)
        let sequences = eligibleRollbacks.map(\.sequence)
        var passwordConflicts: Set<UUID> = []
        var secretEnvConflicts: Set<UUID> = []
        var allRestored = true

        func publishProgress() {
            onProgress?(remaining.enumerated().compactMap { index, transaction in
                guard transaction.password != nil || transaction.secretEnv != nil else { return nil }
                return DestinationSecretsRollback(
                    transaction: transaction,
                    sequence: sequences[index]
                )
            })
        }

        for index in remaining.indices.reversed() {
            let destId = remaining[index].destId

            if let password = remaining[index].password {
                if passwordConflicts.contains(destId) {
                    remaining[index] = DestinationSecretRollback(
                        destId: destId,
                        password: nil,
                        secretEnv: remaining[index].secretEnv,
                        previousSecretEnvRaw: remaining[index].previousSecretEnvRaw,
                        secretEnvGeneration: remaining[index].secretEnvGeneration
                    )
                    publishProgress()
                } else {
                    let result = try await store.restoreDestinationSecretsIfCurrent(
                        DestinationSecretRollback(
                            destId: destId,
                            password: password,
                            secretEnv: nil,
                            passwordGeneration: remaining[index].passwordGeneration
                        )
                    )
                    remaining[index] = DestinationSecretRollback(
                        destId: destId,
                        password: nil,
                        secretEnv: remaining[index].secretEnv,
                        previousSecretEnvRaw: remaining[index].previousSecretEnvRaw,
                        secretEnvGeneration: remaining[index].secretEnvGeneration
                    )
                    if result.passwordRestored == false {
                        passwordConflicts.insert(destId)
                        allRestored = false
                    }
                    publishProgress()
                }
            }

            if let secretEnv = remaining[index].secretEnv {
                if secretEnvConflicts.contains(destId) {
                    remaining[index] = DestinationSecretRollback(
                        destId: destId,
                        password: remaining[index].password,
                        secretEnv: nil,
                        previousSecretEnvRaw: nil,
                        passwordGeneration: remaining[index].passwordGeneration
                    )
                    publishProgress()
                } else {
                    let result = try await store.restoreDestinationSecretsIfCurrent(
                        DestinationSecretRollback(
                            destId: destId,
                            password: nil,
                            secretEnv: secretEnv,
                            previousSecretEnvRaw: remaining[index].previousSecretEnvRaw,
                            secretEnvGeneration: remaining[index].secretEnvGeneration
                        )
                    )
                    remaining[index] = DestinationSecretRollback(
                        destId: destId,
                        password: remaining[index].password,
                        secretEnv: nil,
                        previousSecretEnvRaw: nil,
                        passwordGeneration: remaining[index].passwordGeneration
                    )
                    if result.secretEnvRestored == false {
                        secretEnvConflicts.insert(destId)
                        allRestored = false
                    }
                    publishProgress()
                }
            }
        }
        return allRestored
    }

    /// Transfers rollback ownership out of a disappearing view before its
    /// `@State` is destroyed. No secret is written to disk: the tokens stay
    /// in the process that already held them and a global banner offers an
    /// explicit retry if the backend remains unavailable.
    func retainPendingSecretRollbacks(_ rollbacks: [DestinationSecretsRollback]) {
        guard !rollbacks.isEmpty else { return }
        pendingSecretRollbackBatches.append(rollbacks)
        retryPendingSecretRollbacks()
    }

    /// A successful config commit — or an uncertain commit whose credentials
    /// are deliberately left installed for reconciliation — establishes a
    /// per-field sequence cutoff. That cutoff also protects rollback tokens
    /// still owned by other live views: if they are later reverted or queued
    /// during teardown, restoreDestinationSecrets filters them before I/O.
    func retirePendingSecretRollbackFields(
        committedBy rollbacks: [DestinationSecretsRollback]
    ) {
        for rollback in rollbacks {
            if rollback.transaction.password != nil {
                committedPasswordRollbackSequence[rollback.destId] = max(
                    committedPasswordRollbackSequence[rollback.destId] ?? 0,
                    rollback.sequence
                )
            }
            if rollback.transaction.secretEnv != nil {
                committedSecretEnvRollbackSequence[rollback.destId] = max(
                    committedSecretEnvRollbackSequence[rollback.destId] ?? 0,
                    rollback.sequence
                )
            }
        }

        pendingSecretRollbackBatches = pendingSecretRollbackBatches.compactMap { batch in
            let remaining = batch.compactMap(rollbackWithUncommittedFields)
            return remaining.isEmpty ? nil : remaining
        }
        if pendingSecretRollbackBatches.isEmpty {
            pendingSecretRollbackError = nil
        }
    }

    private func rollbackWithUncommittedFields(
        _ rollback: DestinationSecretsRollback
    ) -> DestinationSecretsRollback? {
        let transaction = rollback.transaction
        let passwordCommitted = transaction.password != nil
            && committedPasswordRollbackSequence[rollback.destId].map {
                rollback.sequence <= $0
            } == true
        let secretEnvCommitted = transaction.secretEnv != nil
            && committedSecretEnvRollbackSequence[rollback.destId].map {
                rollback.sequence <= $0
            } == true
        let password = passwordCommitted ? nil : transaction.password
        let secretEnv = secretEnvCommitted ? nil : transaction.secretEnv
        guard password != nil || secretEnv != nil else { return nil }
        return DestinationSecretsRollback(
            transaction: DestinationSecretRollback(
                destId: transaction.destId,
                password: password,
                secretEnv: secretEnv,
                previousSecretEnvRaw: secretEnv == nil ? nil : transaction.previousSecretEnvRaw,
                passwordGeneration: password == nil ? nil : transaction.passwordGeneration,
                secretEnvGeneration: secretEnv == nil ? nil : transaction.secretEnvGeneration
            ),
            sequence: rollback.sequence
        )
    }

    func retryPendingSecretRollbacks() {
        guard pendingSecretRollbackTask == nil else { return }
        // Do not unwind an older abandoned edit while a live editor may be
        // between changing the keychain and parking/claiming its rollback.
        // Once the editor ends, endSecretEditorSession() resumes newest-first
        // processing with every transaction registered in one place.
        guard activeSecretEditorSessions.isEmpty else { return }
        pendingSecretRollbackError = nil
        pendingSecretRollbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingSecretRollbackTask = nil }
            // Editor teardown order is unrelated to mutation order. Pick one
            // globally newest transaction at a time so interleaved sessions
            // unwind B -> A -> old even when their windows close in any order.
            while !self.pendingSecretRollbackBatches.isEmpty {
                guard let location = self.pendingSecretRollbackBatches.indices
                    .flatMap({ batchIndex in
                        self.pendingSecretRollbackBatches[batchIndex].indices.map { rollbackIndex in
                            (batchIndex, rollbackIndex)
                        }
                    })
                    .max(by: { lhs, rhs in
                        self.pendingSecretRollbackBatches[lhs.0][lhs.1].sequence
                            < self.pendingSecretRollbackBatches[rhs.0][rhs.1].sequence
                    }) else { break }
                let (batchIndex, rollbackIndex) = location
                guard let rollback = self.rollbackWithUncommittedFields(
                    self.pendingSecretRollbackBatches[batchIndex][rollbackIndex]
                ) else {
                    self.pendingSecretRollbackBatches[batchIndex].remove(at: rollbackIndex)
                    if self.pendingSecretRollbackBatches[batchIndex].isEmpty {
                        self.pendingSecretRollbackBatches.remove(at: batchIndex)
                    }
                    continue
                }
                self.pendingSecretRollbackBatches[batchIndex][rollbackIndex] = rollback
                var remaining = [rollback]
                do {
                    _ = try await self.restoreDestinationSecrets(
                        [rollback],
                        onProgress: { progress in
                            remaining = progress
                            guard batchIndex < self.pendingSecretRollbackBatches.count,
                                  rollbackIndex < self.pendingSecretRollbackBatches[batchIndex].count else {
                                return
                            }
                            if let checkpoint = progress.first {
                                self.pendingSecretRollbackBatches[batchIndex][rollbackIndex] = checkpoint
                            } else {
                                self.pendingSecretRollbackBatches[batchIndex].remove(at: rollbackIndex)
                            }
                        }
                    )
                    if batchIndex < self.pendingSecretRollbackBatches.count,
                       self.pendingSecretRollbackBatches[batchIndex].isEmpty {
                        self.pendingSecretRollbackBatches.remove(at: batchIndex)
                    }
                } catch {
                    if batchIndex < self.pendingSecretRollbackBatches.count,
                       rollbackIndex < self.pendingSecretRollbackBatches[batchIndex].count,
                       let checkpoint = remaining.first {
                        self.pendingSecretRollbackBatches[batchIndex][rollbackIndex] = checkpoint
                    }
                    self.pendingSecretRollbackError =
                        "Some destination credentials could not be restored (\(error)). "
                        + "Backups may use credentials from an abandoned edit until restoration succeeds."
                    return
                }
            }
            self.pendingSecretRollbackError = nil
        }
    }

    /// Reads back what the destination editor needs to pre-fill. A missing
    /// password is not an error here (a destination can exist before its
    /// password was ever stored) — the caller shows "leave blank to keep".
    func loadDestinationSecrets(destId: UUID) async -> (password: String?, secretEnv: [String: String]) {
        // A rollback which was already in flight when this editor opened may
        // still own the value currently in the backend. Prefill only after it
        // settles, matching the serialization used by credential writes.
        if let pendingSecretRollbackTask {
            await pendingSecretRollbackTask.value
        }
        guard let store = self.secrets else { return (nil, [:]) }
        let password = try? await store.password(destId: destId)
        let env = (try? await store.secretEnv(destId: destId)) ?? [:]
        return (password, env)
    }

    /// Both stored secrets for a destination, as promised by the remove
    /// confirmation copy. Deletes are idempotent in every `SecretStore`.
    func deleteDestinationSecrets(destId: UUID) async {
        guard let store = self.secrets else { return }
        try? await store.deletePassword(destId: destId)
        try? await store.deleteSecretEnv(destId: destId)
    }

    // MARK: - Probe

    /// `probe-repo` through the helper, classified for the destination
    /// editor's *Test connection* button.
    ///
    /// The destination must already be in the saved config — the helper reads
    /// `config.json` itself — which is why the editor persists before it
    /// probes.
    func probeDestination(setId: UUID, destId: UUID) async -> DestinationProbeOutcome {
        let result = await helper.probeRepo(setId: setId, destId: destId)
        // The helper has written state/repo-status-<destId>.json; pick it up
        // now rather than waiting for the watcher's debounce.
        refresh()

        switch result {
        case .ok(let output):
            return .reachable(Self.trim(output, fallback: "The repository answered."))
        case .offline(let output):
            // A local repository path that does not exist yet is reported as
            // offline by `Reachability.probeLocal` — for a brand-new
            // destination that means "not initialized", not "unreachable".
            return Self.mentionsMissingRepository(output)
                ? .notInitialized(Self.trim(output, fallback: "No repository at this location yet."))
                : .offline(Self.trim(output, fallback: "The destination could not be reached."))
        case .failed(let output):
            // restic exit 10 arrives here: `probe-repo` exits 1 and prints
            // ResticExitClass.repoDoesNotExist's user-facing message.
            return Self.mentionsMissingRepository(output)
                ? .notInitialized(Self.trim(output, fallback: "No repository at this location yet."))
                : .error(Self.trim(output, fallback: "The probe failed."))
        case .busy:
            return .error(result.message + " Wait for it to finish, then try again.")
        }
    }

    /// Recognizes the two ways "there is no repository here" reaches the app:
    /// `ResticExitClass.repoDoesNotExist` (restic exit 10) and
    /// `Reachability.probeLocal`'s missing-path reason. Matching on text is
    /// unavoidable — the helper's contract carries exit codes, not a typed
    /// reason — so both spellings are matched, and both are pinned in Core
    /// (`ResticError.swift`, `Reachability.swift`).
    nonisolated static func mentionsMissingRepository(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("no repository was found")
            || lowercased.contains("repository path does not exist")
            || lowercased.contains("repository does not exist")
    }

    // MARK: - Initialization

    /// The machine-resolved destination used by repository actions launched
    /// from the editor. Kept as a pure lookup so app tests can pin the safety
    /// boundary: initialization must never fall back to the shared raw URL
    /// when this machine overrides it.
    func repositoryActionDestination(setId: UUID, destId: UUID) -> Destination? {
        guard let found = addressableConfig.destination(id: destId), found.set.id == setId else {
            return nil
        }
        return found.destination
    }

    /// *Initialize repository* in the destination editor.
    ///
    /// A **secondary** goes through the helper's `init-secondary` subcommand
    /// (`restic init --from-repo … --copy-chunker-params`), which takes the
    /// per-set lock and writes a run record like every other mutating
    /// operation.
    ///
    /// A **primary** does not: the helper has no `init-primary` subcommand
    /// (T10 ships `tick`, `run-set`, `init-secondary`, `probe-repo`,
    /// `restore`, `fda-check`, `version`), so this is the one mutating
    /// operation the app performs itself, through `ResticRunner`. It is
    /// deliberately confined to this method. Consequences, accepted for v1
    /// and flagged in the T14 PR: no per-set lock and no run record for a
    /// primary init. `restic init` on an empty location is idempotent-ish —
    /// it refuses to overwrite an existing repository — so the missing lock
    /// cannot corrupt data. The fix is a helper `init-primary` subcommand;
    /// this method should then collapse into `HelperInvoker`.
    func initializeRepository(setId: UUID, destId: UUID) async -> DestinationInitOutcome {
        // The **addressable** view, so the repository this creates is the one
        // this machine backs up to. A raw `config` destination would init
        // `/Volumes/Big/…` on a host whose override says `/mnt/big/…` —
        // creating (or probing) a repository nothing ever writes to.
        guard let destination = repositoryActionDestination(setId: setId, destId: destId) else {
            return .failed(
                "This destination has not been saved yet. Save the backup set, then initialize."
            )
        }

        if destination.isPrimary {
            return await initializePrimaryRepository(destination)
        }

        let result = await helper.initSecondary(setId: setId, destId: destId)
        refresh()
        switch result {
        case .ok(let output):
            return .initialized(Self.trim(output, fallback: "Repository initialized."))
        case .busy:
            return .failed(result.message + " Wait for it to finish, then try again.")
        case .offline(let output), .failed(let output):
            return .failed(Self.trim(
                output,
                fallback: "The repository could not be initialized. See Runs for the log."
            ))
        }
    }

    /// See `initializeRepository(setId:destId:)` for why this bypasses the
    /// helper. Everything else about the invocation is the shared Core path:
    /// argv from `ResticCommand.initRepo`, env and the secret pre-flight
    /// from `ResticRunner`.
    private func initializePrimaryRepository(_ destination: Destination) async -> DestinationInitOutcome {
        guard let resticPath = resticPath, !resticPath.isEmpty else {
            return .failed("No restic binary is configured. Set the restic path in Settings, then try again.")
        }
        guard let secrets = self.secrets else {
            return .failed(
                "Secret storage is misconfigured (check \(SecretBackend.environmentKey)), "
                    + "so the repository password could not be read."
            )
        }
        let runner = ResticRunner(
            resticPath: resticPath,
            paths: paths,
            secrets: secrets,
            runner: DefaultProcessRunner()
        )
        do {
            let outcome = try await runner.run(
                .initRepo(repo: destination.repoURL),
                for: ResticInvocation(destination: destination),
                timeout: Self.primaryInitTimeout
            )
            guard outcome.status.isSuccess else {
                return .failed(outcome.status.userFacingMessage)
            }
            refresh()
            return .initialized("Repository initialized at \(destination.repoURL).")
        } catch let error as ResticRunnerError {
            return .failed(error.userFacingMessage)
        } catch {
            return .failed("The repository could not be initialized: \(error)")
        }
    }

    /// `restic init` is a handful of small writes; a repository that has not
    /// answered in two minutes is not going to.
    private static var primaryInitTimeout: TimeInterval { 120 }

    /// Verifies the SSH transport and remote restic version used for SFTP
    /// maintenance. This is deliberately a `version --json` invocation: it
    /// neither reads nor sends the repository password and cannot fall back
    /// to a local maintenance command.
    func testRemoteMaintenance(setId: UUID, destId: UUID) async -> RemoteMaintenanceTestOutcome {
        guard let destination = repositoryActionDestination(setId: setId, destId: destId),
              destination.remoteMaintenance?.enabled == true,
              let operands = destination.remoteMaintenanceOperands() else {
            return .failed("Configure an SFTP destination and its remote maintenance details first.")
        }
        guard let resticPath, !resticPath.isEmpty else {
            return .failed("No restic binary is configured. Set the restic path in Settings, then try again.")
        }
        guard let secrets = self.secrets else {
            return .failed("Secret storage is misconfigured (check \(SecretBackend.environmentKey)).")
        }

        let runner = ResticRunner(
            resticPath: resticPath,
            paths: paths,
            secrets: secrets,
            runner: DefaultProcessRunner()
        )
        do {
            let version = try await runner.verifyRemoteMaintenance(
                .version(sshTarget: operands.sshTarget, resticPath: operands.resticPath)
            )
            return .available("SSH and remote restic \(version.version) are ready for pack reclamation.")
        } catch let error as ResticRunnerError {
            return .failed(error.userFacingMessage)
        } catch {
            return .failed("Remote maintenance could not be verified: \(error)")
        }
    }

    private static func trim(_ output: String, fallback: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

// MARK: - Outcomes

/// The result of *Test connection*, in the four states `docs/ui-spec.md`
/// §Backup Sets asks the destination editor to distinguish.
enum DestinationProbeOutcome: Equatable, Sendable {
    case reachable(String)
    /// restic reached the location and found no repository — surface
    /// *Initialize repository* prominently (ui-spec: "If probe says
    /// 'repo does not exist' (exit 10), surface Initialize prominently").
    case notInitialized(String)
    /// Expected and non-alarming: an unplugged volume, a network that is down.
    case offline(String)
    case error(String)
}

/// The result of *Initialize repository*.
enum DestinationInitOutcome: Equatable, Sendable {
    case initialized(String)
    case failed(String)
}

/// The result of testing remote SFTP maintenance from the destination editor.
enum RemoteMaintenanceTestOutcome: Equatable, Sendable {
    case available(String)
    case failed(String)
}
