//
//  APIKeySetupViewModel.swift
//  RailtracksSwiftDemo
//

import Foundation

@Observable
class APIKeySetupViewModel {
    var keyInput: String = ""
    var isSaveDisabled: Bool {
        keyInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var onSave: (() -> Void)?

    func save() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        KeychainHelper.writeOpenAIKey(trimmed)
        onSave?()
    }
}
