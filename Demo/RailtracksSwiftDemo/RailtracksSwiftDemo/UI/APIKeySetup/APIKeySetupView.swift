//
//  APIKeySetupView.swift
//  RailtracksSwiftDemo
//

import SwiftUI

struct APIKeySetupView: View {
    @State private var viewModel: APIKeySetupViewModel
    @Environment(\.dismiss) private var dismiss
    private let isUpdate: Bool
    private let provider: DemoAPIKeyProvider

    init(provider: DemoAPIKeyProvider, isUpdate: Bool = false, onSave: @escaping () -> Void) {
        self.provider = provider
        self.isUpdate = isUpdate
        let vm = APIKeySetupViewModel(provider: provider)
        vm.onSave = onSave
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(isUpdate ? "Update \(provider.displayName) API Key" : "\(provider.displayName) API Key Required")
                .font(.headline)
            Text("Enter your \(provider.displayName) API key. It will be stored securely in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("sk-...", text: $viewModel.keyInput)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                viewModel.save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSaveDisabled)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
