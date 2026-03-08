import SwiftUI

struct ContactDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let connection: Connection

    @State private var howDoIKnow: String
    @State private var isSaving = false
    @State private var savedSuccessfully = false
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var isTogglingPause = false

    init(connection: Connection) {
        self.connection = connection
        self._howDoIKnow = State(initialValue: connection.howDoIKnow)
    }

    private var hasChanges: Bool {
        howDoIKnow.trimmingCharacters(in: .whitespacesAndNewlines) != connection.howDoIKnow
    }

    /// Get the live connection from the service so isPaused updates in real time
    private var liveConnection: Connection {
        appState.connectionsService.connections.first { $0.userId == connection.userId } ?? connection
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Profile photo
                    AsyncProfileImage(url: connection.profilePhotoURL)
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.separator, lineWidth: 1))

                    // Name
                    Text(connection.fullName)
                        .font(.title2.bold())

                    // Connected since
                    Text("Connected \(connection.connectedAt, style: .relative) ago")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Proximity status
                    if liveConnection.proximityPaused {
                        Label("Proximity detection paused", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    // How do I know this person (editable)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How do I know this person?")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("e.g. Met at conference, Friend of a friend...", text: $howDoIKnow)
                            .padding()
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    // Save button (only shown when there are changes)
                    if hasChanges {
                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Save")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isSaving)
                        .padding(.horizontal)
                    }

                    if savedSuccessfully {
                        Text("Saved!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    // Send Message button
                    NavigationLink {
                        ConversationView(
                            connection: connection,
                            currentUID: appState.authService.currentUID ?? ""
                        )
                    } label: {
                        Label("Send Message", systemImage: "bubble.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    // Disconnect / Reconnect button
                    Button {
                        Task { await togglePause() }
                    } label: {
                        if isTogglingPause {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else if liveConnection.proximityPaused {
                            Label("Reconnect Proximity", systemImage: "wifi")
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Disconnect Proximity", systemImage: "wifi.slash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(liveConnection.proximityPaused ? .green : .orange)
                    .disabled(isTogglingPause)
                    .padding(.horizontal)

                    // Delete Contact button
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        if isDeleting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Delete Contact", systemImage: "person.badge.minus")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isDeleting)
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
                .padding(.top, 32)
            }
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Delete Contact", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Task { await deleteContact() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \(connection.fullName) from your contacts and delete all messages between you. This cannot be undone.")
            }
        }
    }

    private func save() async {
        guard let myUID = appState.authService.currentUID else { return }

        isSaving = true
        savedSuccessfully = false

        do {
            try await appState.connectionsService.updateHowDoIKnow(
                myUID: myUID,
                connectionUID: connection.userId,
                howDoIKnow: howDoIKnow.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            savedSuccessfully = true
        } catch {
            print("[ContactDetailSheet] save failed: \(error.localizedDescription)")
        }

        isSaving = false
    }

    private func togglePause() async {
        guard let myUID = appState.authService.currentUID else { return }

        isTogglingPause = true

        do {
            let newPaused = !liveConnection.proximityPaused
            try await appState.connectionsService.togglePause(
                myUID: myUID,
                connectionUID: connection.userId,
                paused: newPaused
            )
        } catch {
            print("[ContactDetailSheet] togglePause failed: \(error.localizedDescription)")
        }

        isTogglingPause = false
    }

    private func deleteContact() async {
        guard let myUID = appState.authService.currentUID else { return }

        isDeleting = true

        do {
            // Delete the conversation and all messages
            try await appState.messagingService.deleteConversation(
                myUID: myUID,
                otherUID: connection.userId
            )

            // Remove the connection (both sides)
            try await appState.connectionsService.removeConnection(
                myUID: myUID,
                connectionUID: connection.userId
            )

            dismiss()
        } catch {
            print("[ContactDetailSheet] deleteContact failed: \(error.localizedDescription)")
            isDeleting = false
        }
    }
}
