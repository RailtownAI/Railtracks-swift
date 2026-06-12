//
//  APIKeySetupView.swift
//  RailtracksSwiftDemo
//

import SwiftUI

struct APIKeySetupView: View {
    @State private var viewModel: APIKeySetupViewModel
    @Environment(\.dismiss) private var dismiss
    private let isUpdate: Bool

    init(isUpdate: Bool = false, onSave: @escaping () -> Void) {
        self.isUpdate = isUpdate
        let vm = APIKeySetupViewModel()
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
            Text(isUpdate ? "Update API Key" : "API Key Required")
                .font(.headline)
            Text("Enter your OpenAI API key. It will be stored securely in the Keychain.")
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
