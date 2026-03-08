import SwiftUI
import PhotosUI

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ProfileViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingPhotoPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let user = appState.userService.currentAppUser {
                    Spacer()

                    if viewModel.isEditing {
                        editingContent(user: user)
                    } else {
                        displayContent(user: user)
                    }

                    Spacer()

                    if !viewModel.isEditing {
                        VStack(spacing: 12) {
                            // Admin Dashboard link (only for admins)
                            if appState.isAdmin {
                                NavigationLink {
                                    AdminDashboardView()
                                } label: {
                                    Label("Admin Dashboard", systemImage: "shield.checkered")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.indigo)
                                .controlSize(.large)
                                .padding(.horizontal)
                            }

                            // Per-field invitation toggles
                            VStack(spacing: 8) {
                                Text("Invitation preferences")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if let email = user.email {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Email")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(email)
                                                .font(.subheadline)
                                        }
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { viewModel.emailSearchable },
                                            set: { newValue in
                                                viewModel.emailSearchable = newValue
                                                Task { await viewModel.updateSearchablePreference(field: "email", using: appState) }
                                            }
                                        ))
                                        .labelsHidden()
                                    }
                                    .padding(12)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Phone")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(user.phone ?? "Not set")
                                            .font(.subheadline)
                                            .foregroundStyle(user.phone != nil ? .primary : .tertiary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { viewModel.phoneSearchable },
                                        set: { newValue in
                                            viewModel.phoneSearchable = newValue
                                            Task { await viewModel.updateSearchablePreference(field: "phone", using: appState) }
                                        }
                                    ))
                                    .labelsHidden()
                                }
                                .padding(12)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                                Text("Toggle on to let others find and invite you by that method")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)

                            Button(role: .destructive) {
                                appState.onSignOut()
                            } label: {
                                Text("Sign Out")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button(role: .destructive) {
                                viewModel.showingDeleteConfirmation = true
                            } label: {
                                if viewModel.isDeleting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Delete Account")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.large)
                            .foregroundStyle(.red)
                            .disabled(viewModel.isDeleting)

                            if let error = viewModel.deleteError {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 32)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Profile")
            .onAppear { viewModel.loadUser(from: appState) }
            .alert("Delete Account", isPresented: $viewModel.showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deleteAccount(using: appState)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your account and all your data. This cannot be undone.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.userService.currentAppUser != nil {
                        if viewModel.isEditing {
                            Button("Cancel") {
                                viewModel.cancelEditing()
                            }
                        } else {
                            Button("Edit") {
                                viewModel.startEditing(from: appState)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Display Mode

    @ViewBuilder
    private func displayContent(user: AppUser) -> some View {
        AsyncProfileImage(url: user.profilePhotoURL)
            .frame(width: 120, height: 120)
            .clipShape(Circle())
            .overlay(Circle().stroke(.separator, lineWidth: 1))

        VStack(spacing: 4) {
            Text(user.fullName)
                .font(.title2.bold())

            if let email = user.email {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let lat = appState.locationService.currentLatitude,
               let lon = appState.locationService.currentLongitude {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                    Text(String(format: "%.4f, %.4f", lat, lon))
                        .font(.caption)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }

        if let message = viewModel.successMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.green)
                .transition(.opacity)
        }
    }

    // MARK: - Editing Mode

    @ViewBuilder
    private func editingContent(user: AppUser) -> some View {
        // Tappable profile photo with camera badge
        profilePhotoEditor(currentURL: user.profilePhotoURL)

        // Name fields
        VStack(spacing: 12) {
            TextField("First Name", text: $viewModel.firstName)
                .textFieldStyle(.roundedBorder)
                .textContentType(.givenName)
                .autocorrectionDisabled()

            TextField("Last Name", text: $viewModel.lastName)
                .textFieldStyle(.roundedBorder)
                .textContentType(.familyName)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 32)

        // Error message
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }

        // Save button
        Button {
            Task {
                await viewModel.save(using: appState)
            }
        } label: {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text("Save Changes")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!viewModel.hasChanges || !viewModel.isNameValid || viewModel.isLoading)
        .padding(.horizontal, 32)
    }

    // MARK: - Profile Photo Editor

    @ViewBuilder
    private func profilePhotoEditor(currentURL: String?) -> some View {
        VStack(spacing: 12) {
            // Single photo circle — shows new selection or current photo
            ZStack(alignment: .bottomTrailing) {
                if let image = viewModel.selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 150, height: 150)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.secondary, lineWidth: 2))
                } else {
                    AsyncProfileImage(url: currentURL)
                        .frame(width: 150, height: 150)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.secondary, lineWidth: 2))
                }

                // Camera badge
                Image(systemName: "camera.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white, .blue)
                    .offset(x: -4, y: -4)
            }
            .onTapGesture {
                viewModel.showingPhotoOptions = true
            }

            Text("Tap photo to change")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Show remove button if a new image was selected
            if viewModel.selectedImage != nil {
                Button("Remove New Selection", role: .destructive) {
                    viewModel.selectedImage = nil
                }
                .font(.caption)
            }
        }
        .confirmationDialog("Change Profile Photo", isPresented: $viewModel.showingPhotoOptions) {
            Button("Choose from Library") {
                showingPhotoPicker = true
            }
            Button("Take Photo") {
                viewModel.requestCameraAccess()
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, newItem in
            Task {
                guard let newItem else { return }
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    viewModel.selectedImage = uiImage
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $viewModel.showingCamera) {
            CameraView(image: $viewModel.selectedImage)
                .ignoresSafeArea()
        }
        .alert("Camera Access Required", isPresented: $viewModel.showingCameraDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Camera access was previously denied. Please enable it in Settings to take a photo.")
        }
    }
}
