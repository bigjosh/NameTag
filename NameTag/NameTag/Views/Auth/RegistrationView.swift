import SwiftUI

struct RegistrationView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = RegistrationViewModel()

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.currentStep {
            case .credentials:
                credentialsStep
            case .profile:
                profileStep
            case .photo:
                photoStep
            }
        }
        .padding()
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Error banner (shown on every step)
    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Step 1: Email & Password
    private var credentialsStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Enter your email and password")
                .font(.headline)

            TextField("Email", text: $viewModel.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding()
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            SecureField("Password (6+ characters)", text: $viewModel.password)
                .textContentType(.newPassword)
                .padding()
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Inline validation hints
            if !viewModel.email.isEmpty && !viewModel.isEmailValid {
                Text("Enter a valid email (e.g. name@example.com)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !viewModel.password.isEmpty && !viewModel.isPasswordValid {
                Text("Password must be at least 6 characters")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Stay logged in", isOn: $viewModel.stayLoggedIn)
                .font(.subheadline)

            errorBanner

            Button("Next") {
                viewModel.errorMessage = nil
                viewModel.currentStep = .profile
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.isCredentialsStepValid)

            Spacer()
        }
    }

    // MARK: - Step 2: Name & Contact Preferences
    private var profileStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("What's your name?")
                .font(.headline)

            TextField("First Name", text: $viewModel.firstName)
                .textContentType(.givenName)
                .padding()
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            TextField("Last Name", text: $viewModel.lastName)
                .textContentType(.familyName)
                .padding()
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Contact preferences
            VStack(spacing: 12) {
                Text("Invitation preferences")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Email row: display email from step 1 with toggle
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Email")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.email)
                            .font(.subheadline)
                    }
                    Spacer()
                    Toggle("", isOn: $viewModel.emailSearchable)
                        .labelsHidden()
                }
                .padding(12)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Phone row: editable phone with toggle
                HStack {
                    TextField("Phone (optional)", text: $viewModel.phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $viewModel.phoneSearchable)
                        .labelsHidden()
                }
                .padding(12)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if !viewModel.phone.isEmpty && !viewModel.isPhoneValid {
                    Text("Phone number must be 10 digits including area code")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Toggle on to let others find and invite you by that method")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            errorBanner

            Button("Next") {
                viewModel.errorMessage = nil
                viewModel.currentStep = .photo
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.isProfileStepValid)

            Button("Back") {
                viewModel.errorMessage = nil
                viewModel.currentStep = .credentials
            }
            .foregroundStyle(.secondary)

            Spacer()
        }
    }

    // MARK: - Step 3: Photo
    private var photoStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Add a profile photo")
                .font(.headline)

            Text("This is how nearby contacts will see you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            PhotoPickerView(selectedImage: $viewModel.selectedImage)

            errorBanner

            Button {
                Task { await viewModel.register(using: appState) }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Create Account")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isLoading || !viewModel.isPhotoStepValid)

            Button("Back") {
                viewModel.errorMessage = nil
                viewModel.currentStep = .profile
            }
            .foregroundStyle(.secondary)
            .disabled(viewModel.isLoading)

            Spacer()
        }
    }
}
