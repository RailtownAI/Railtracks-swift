//
//  RTSValue+SignpostText.swift
//  RailtracksSwift
//

import Foundation

extension RTSValue {
    /// Text rendering of a value for Instruments: the Tool I/O kwarg/output rows and the Node
    /// Runs input summary share it, so both lanes show a value the same way. Scalars render bare,
    /// arrays and objects as compact JSON with sorted keys, and images (at any depth) as a short
    /// `[image <mime>]` placeholder so no image data reaches a signpost.
    var signpostText: String {
        switch self {
        case .null:           return "null"
        case .bool(let b):   return b ? "true" : "false"
        case .number(let n): return "\(n)"
        case .string(let s): return s
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(replacingImagesWithPlaceholders()),
                  let str = String(data: data, encoding: .utf8) else { return "\(self)" }
            return str
        case .image(let image):
            return Self.imagePlaceholder(image)
        }
    }

    static func imagePlaceholder(_ image: RTSImage) -> String {
        "[image \(image.mimeType)]"
    }

    /// Swaps nested images for their placeholder string, so the JSON rendering of a container
    /// shows `"[image <mime>]"` rather than the image's trace descriptor.
    private func replacingImagesWithPlaceholders() -> RTSValue {
        switch self {
        case .array(let elements):
            return .array(elements.map { $0.replacingImagesWithPlaceholders() })
        case .object(let props):
            return .object(props.mapValues { $0.replacingImagesWithPlaceholders() })
        case .image(let image):
            return .string(Self.imagePlaceholder(image))
        case .null, .bool, .number, .string:
            return self
        }
    }
}
