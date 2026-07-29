//
//  APIKeySetupViewModel.swift
//  RailtracksSwiftDemo
//

import Foundation

@Observable
class APIKeySetupViewModel {
    let provider: DemoAPIKeyProvider
    var keyInput: String = ""
    var isSaveDisabled: Bool {
        keyInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var onSave: (() -> Void)?

    init(provider: DemoAPIKeyProvider) {
        self.provider = provider
    }

    func save() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        provider.writeKey(trimmed)
        onSave?()
    }
}
