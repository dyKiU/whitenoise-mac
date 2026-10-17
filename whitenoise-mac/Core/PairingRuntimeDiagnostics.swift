#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import OSLog

    /// Local opt-in diagnostics. The SDK event's identities and free text never reach a log.
    @MainActor
    enum PairingRuntimeDiagnostics {
        private static let log = Logger(subsystem: "dev.ipf.whitenoise.mac", category: "DeviceVerification")

        // Static Engine/Storage error kinds from the experimental SDK. Unknown kinds
        // stay visible as an unclassified failure without exporting backend details.
        private static let kinds: Set<String> = [
            "blocking_task", "transport", "io", "json", "sqlite", "hex", "backend", "other",
            "unknown_group", "group_not_hydrated", "unknown_pending", "not_a_member", "not_group_admin",
            "unknown_member", "invalid_credential_identity", "admin_cannot_self_remove", "leave_already_requested",
            "admin_depletion", "missing_required_capabilities", "disbanding_unsupported_members",
            "disbanding_not_enabled", "unsupported_ciphersuite", "invalid_app_message_payload",
            "invalid_account_identity_proof", "invalid_key_package_lifetime", "invalid_key_package_capabilities",
            "app_message_epoch_mismatch", "app_message_epoch_unsettled", "forked_epoch", "queued_outbound_at_capacity",
            "group_unrecoverable_repair_required", "invalid_transition", "peeler", "serialize", "invalid_welcome",
            "linking_welcome_denied", "selected_chat_welcome_denied", "missing_welcome_key_package",
            "welcome_already_processed", "private_enrollment_intake_at_capacity", "storage",
            "storage_not_found", "storage_already_exists", "storage_record_denied_by_departure",
            "storage_snapshot_missing", "storage_timeline_cursor_expired", "storage_busy", "storage_corruption",
            "storage_capacity", "storage_closed", "storage_unsupported_schema_version", "storage_backend",
            "storage_serialization",
        ]

        static func receiveFailure(_ event: MarmotEventFfi, accountIdHex: String) -> String? {
            guard case .accountError(let changedAccount, _, let message) = event,
                changedAccount.lowercased() == accountIdHex.lowercased()
            else { return nil }
            let prefix = "runtime receive failed: "
            guard message.hasPrefix(prefix) else { return nil }
            let kind = String(message.dropFirst(prefix.count))
            return kinds.contains(kind) ? kind : "unclassified"
        }

        static func start(
            runtime: any MarmotRuntime, accountIdHex: String,
            enabled: Bool = ProcessInfo.processInfo.environment["WN_PAIRING_DIAGNOSTICS"] == "1",
            emit: @escaping @MainActor (String) -> Void = { kind in
                log.notice("[device-verification] Pairing runtime receive failed category=\(kind, privacy: .public)")
            }
        ) -> Task<Void, Never>? {
            guard enabled else { return nil }
            // Subscribe synchronously before the caller can approve enrollment.
            let subscription = runtime.subscribeEvents()
            return Task {
                do {
                    while !Task.isCancelled {
                        guard let event = try await runtime.nextEvent(subscription: subscription) else { return }
                        guard !Task.isCancelled else { return }
                        if let kind = receiveFailure(event, accountIdHex: accountIdHex) { emit(kind) }
                    }
                } catch {
                    // A cancelled/closed observation cannot authorize a retry or change the owner.
                }
            }
        }
    }
#endif
