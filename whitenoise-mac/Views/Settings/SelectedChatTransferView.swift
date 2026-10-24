#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import SwiftUI

    struct SelectedChatTransferView: View {
        let model: SelectedChatTransferViewModel
        var groupIdHex: String? = nil
        @State private var selectedTarget: Data?
        @State private var incoming = ""
        @State private var actionFailed = false
        @State private var actionTask: Task<Void, Never>?

        var body: some View {
            SettingsSection(title: String(localized: "Copy chat to linked devices")) {
                if let groupIdHex, model.copy?.isActive != true {
                    SelectedChatPacketView(title: String(localized: "Chat ID"), packet: groupIdHex)
                    Picker("Existing device group", selection: $selectedTarget) {
                        Text("Choose a target").tag(Optional<Data>.none)
                        ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
                            Text("Target \(index + 1)").tag(Optional(target.selector))
                        }
                    }
                    if let selectedTarget {
                        SelectedChatPacketView(
                            title: String(localized: "Existing device group"),
                            packet: selectedTarget.map { String(format: "%02x", $0) }.joined())
                    }
                    HStack {
                        Button("Refresh") {
                            perform {
                                try await model.loadTargets()
                                selectedTarget = nil
                            }
                        }
                        Button("Copy chat to linked devices") {
                            guard let selectedTarget else { return }
                            perform {
                                try await model.begin(groupIdHex: groupIdHex, linkedRosterSelector: selectedTarget)
                            }
                        }
                        .disabled(selectedTarget == nil)
                    }
                }
                if let copy = model.copy, copy.isActive || copy.cleanupError != nil {
                    if let originalGroup = model.copyGroupIdHex {
                        SelectedChatPacketView(title: String(localized: "Chat ID"), packet: originalGroup)
                    }
                    SelectedChatCopyControls(model: copy).id(ObjectIdentifier(copy))
                }
                if model.consent?.isActive != true {
                    TextField("Opaque packet from the other device", text: $incoming, axis: .vertical).lineLimit(2...4)
                    Button("Review chat request") {
                        let packet = incoming
                        perform {
                            try await model.receive(input: packet)
                            incoming = ""
                        }
                    }
                    .disabled(incoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let consent = model.consent, consent.isActive || consent.cleanupError != nil {
                    SelectedChatConsentControls(model: consent).id(ObjectIdentifier(consent))
                }
                if actionFailed { Text("Chat copy action failed. Retry or cancel.").foregroundStyle(.red) }
            }
            .disabled(!model.isActive || model.isWorking)
            .task {
                guard groupIdHex != nil, model.isActive else { return }
                do { try await model.loadTargets() } catch { if model.isActive { actionFailed = true } }
            }
            .onDisappear { actionTask?.cancel() }
            .onChange(of: model.isActive) { _, active in
                if !active {
                    actionTask?.cancel()
                    incoming = ""
                    selectedTarget = nil
                    actionFailed = false
                }
            }
        }
        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            guard model.isActive, actionTask == nil else { return }
            actionFailed = false
            actionTask = Task {
                defer { actionTask = nil }
                do { try await action() } catch { if !Task.isCancelled, model.isActive { actionFailed = true } }
            }
        }
    }

    struct SelectedChatCopyEntryView: View {
        let model: SelectedChatTransferViewModel
        let groupIdHex: String
        @State private var isPresented = false
        var body: some View {
            HStack {
                Spacer()
                Button("Copy chat to linked devices") { isPresented = true }
                    .disabled(!model.isActive)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .sheet(isPresented: $isPresented) {
                VStack {
                    HStack {
                        Text("Copy chat to linked devices").font(.headline)
                        Spacer()
                        Button("Close") { isPresented = false }
                    }
                    ScrollView { SelectedChatTransferView(model: model, groupIdHex: groupIdHex) }
                }
                .padding().frame(minWidth: 650, idealHeight: 600)
            }
            .onChange(of: model.isActive) { _, active in if !active { isPresented = false } }
        }
    }

    private struct SelectedChatCopyControls: View {
        let model: SelectedChatCopyViewModel?
        @State private var incoming = ""
        @State private var task: Task<Void, Never>?
        @State private var readFailed = false
        var body: some View {
            Group {
                if let model {
                    if let snapshot = model.snapshot {
                        if snapshot.phase == .awaitingSiblingConsent {
                            LabeledContent("Existing devices", value: String(snapshot.siblingCount))
                            TextField("Opaque packet from the other device", text: $incoming, axis: .vertical)
                                .lineLimit(
                                    2...4)
                            HStack {
                                Button("Export chat request") { perform(.request, revision: snapshot.revision) }
                                Button("Receive chat consent") { perform(.consent, revision: snapshot.revision) }
                                Button("Receive chat offer") { perform(.offer, revision: snapshot.revision) }
                            }
                            Button("Continue chat copy") { perform(.continueCopy, revision: snapshot.revision) }
                        } else if snapshot.phase == .inviteConfirmed {
                            Text("Done")
                        } else {
                            Text("Chat request ended.")
                        }
                    }
                    if let packet = model.outgoingPacket {
                        SelectedChatPacketView(title: String(localized: "Copy"), packet: packet)
                    }
                    HStack {
                        Button("Refresh") { refresh() }.disabled(!model.isActive)
                        Button(L10n.string("Cancel")) { run { try await model.cancel() } }
                    }
                    .disabled(model.isWorking)
                    if readFailed || model.actionError != nil || model.cleanupError != nil {
                        Text("Chat copy action failed. Retry or cancel.").foregroundStyle(.red)
                    }
                } else {
                    Text("Waiting")
                }
            }
            .onDisappear { task?.cancel() }
            .onChange(of: model?.isActive) { _, active in
                if active != true {
                    task?.cancel()
                    incoming = ""
                    readFailed = false
                }
            }
        }
        private func refresh() {
            guard let model else { return }
            run { try await model.refresh() }
        }
        private func perform(_ action: SelectedChatCopyViewModel.Action, revision: UInt64) {
            guard let model else { return }
            let packet = incoming
            run {
                try await model.perform(action, displayedRevision: revision, input: packet)
                incoming = ""
            }
        }
        private func run(_ action: @escaping @MainActor () async throws -> Void) {
            guard task == nil else { return }
            readFailed = false
            task = Task {
                defer { task = nil }
                do { try await action() } catch { if !Task.isCancelled { readFailed = true } }
            }
        }
    }

    private struct SelectedChatConsentControls: View {
        let model: SelectedChatConsentViewModel?
        @State private var task: Task<Void, Never>?
        @State private var readFailed = false
        var body: some View {
            Group {
                if let model {
                    if let snapshot = model.snapshot {
                        SelectedChatPacketView(
                            title: String(localized: "Chat ID"),
                            packet: snapshot.chatSelector.map { String(format: "%02x", $0) }.joined())
                        Text("Approval applies only to this chat.")
                        if snapshot.phase == .awaitingApproval {
                            Button("Approve") { perform(.approve, revision: snapshot.revision) }
                        } else if snapshot.phase == .approved {
                            HStack {
                                Button("Export chat consent") { perform(.response, revision: snapshot.revision) }
                                Button("Export chat offer") { perform(.offer, revision: snapshot.revision) }
                            }
                        } else {
                            Text("Chat request ended.")
                        }
                    }
                    if let packet = model.outgoingPacket {
                        SelectedChatPacketView(title: String(localized: "Copy"), packet: packet)
                    }
                    HStack {
                        Button("Refresh") { run { try await model.refresh() } }.disabled(!model.isActive)
                        Button(L10n.string("Cancel")) { run { try await model.cancel() } }
                    }
                    .disabled(model.isWorking)
                    if readFailed || model.actionError != nil || model.cleanupError != nil {
                        Text("Chat copy action failed. Retry or cancel.").foregroundStyle(.red)
                    }
                } else {
                    Text("Waiting")
                }
            }
            .onDisappear { task?.cancel() }
            .onChange(of: model?.isActive) { _, active in
                if active != true {
                    task?.cancel()
                    readFailed = false
                }
            }
        }
        private func perform(_ action: SelectedChatConsentViewModel.Action, revision: UInt64) {
            guard let model else { return }
            run { try await model.perform(action, displayedRevision: revision) }
        }
        private func run(_ action: @escaping @MainActor () async throws -> Void) {
            guard task == nil else { return }
            readFailed = false
            task = Task {
                defer { task = nil }
                do { try await action() } catch { if !Task.isCancelled { readFailed = true } }
            }
        }
    }

    private struct SelectedChatPacketView: View {
        let title: String
        let packet: String
        var body: some View {
            Text(title)
            Text(packet).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            CopyToClipboardButton(value: packet, actionDescription: L10n.string("Copy")) { _ in Text("Copy") }
        }
    }
    #Preview {
        SelectedChatTransferView(
            model: .init(
                begin: { _, _ in throw MarmotKitError.SelectedChatCopyClosed },
                receive: { _ in throw MarmotKitError.SelectedChatCopyClosed }, targets: { [] }, isCurrent: { true })
        )
        .padding().frame(width: 650)
    }
    #Preview("Chat copy entry") {
        SelectedChatCopyEntryView(
            model: .init(
                begin: { _, _ in throw MarmotKitError.SelectedChatCopyClosed },
                receive: { _ in throw MarmotKitError.SelectedChatCopyClosed }, targets: { [] }, isCurrent: { true }),
            groupIdHex: String(repeating: "01", count: 32))
    }
    #Preview("Copy controls") { SelectedChatCopyControls(model: nil) }
    #Preview("Consent controls") { SelectedChatConsentControls(model: nil) }
    #Preview("Opaque packet") { SelectedChatPacketView(title: "Packet", packet: "AQID") }
#endif
