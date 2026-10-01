//
//  SignpostInputSummaryTests.swift
//  RailtracksSwiftTests
//

import Testing
import Foundation
@testable import RailtracksSwift

extension RailtracksSwiftTestSuite {
    /// `RTSSignpostEmitter.inputSummary` is the text Instruments shows when hovering a node's
    /// Node Runs bar: the prompt for an agent, the arguments for a tool or function.
    @Suite("Signpost input summary", .serialized)
    struct SignpostInputSummaryTests {

        private let image = RTSImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")

        @Test("an agent's summary is the prompt it sends as its user message")
        func agentPrompt() {
            let input: RTSInput = [
                "prompt": .string("What's the weather in Vancouver?"),
                "systemMessage": .string("You are a helpful assistant.")
            ]
            let summary = RTSSignpostEmitter.inputSummary(input, nodeType: .agent)
            #expect(summary == RTSAgentInput.prompt(in: input))
            #expect(summary == "What's the weather in Vancouver?")
        }

        @Test("an agent's attached images become placeholders after the prompt")
        func agentPromptWithImages() {
            let input: RTSInput = [
                "prompt": .string("Describe this"),
                "images": .array([.image(image)])
            ]
            let summary = RTSSignpostEmitter.inputSummary(input, nodeType: .agent)
            #expect(summary == "Describe this [image image/png]")
            #expect(!summary.contains(image.base64Data))
        }

        @Test("tool arguments render as sorted key/value pairs with nested objects and arrays")
        func toolArguments() {
            let input: RTSInput = [
                "city": .string("Vancouver"),
                "options": .object(["units": .string("metric"), "days": .number(3)]),
                "tags": .array([.string("a"), .bool(true), .null])
            ]
            let summary = RTSSignpostEmitter.inputSummary(input, nodeType: .tool)
            #expect(summary == #"city: Vancouver, options: {"days":3,"units":"metric"}, tags: ["a",true,null]"#)
        }

        @Test("image values, top-level or nested, become a placeholder")
        func imagePlaceholder() {
            let input: RTSInput = [
                "photo": .image(image),
                "batch": .object(["first": .image(image)])
            ]
            let summary = RTSSignpostEmitter.inputSummary(input, nodeType: .function)
            #expect(summary == #"batch: {"first":"[image image/png]"}, photo: [image image/png]"#)
            #expect(!summary.contains(image.base64Data))
        }

        @Test("empty input gives an empty summary", arguments: [RTSFlowNodeType.agent, .tool, .function])
        func emptyInput(nodeType: RTSFlowNodeType) {
            #expect(RTSSignpostEmitter.inputSummary([:], nodeType: nodeType) == "")
        }

        @Test("a huge input stops rendering past the limit")
        func hugeInput() {
            var input: RTSInput = [:]
            for index in 0..<200 {
                input[String(format: "key%03d", index)] = .string(String(repeating: "x", count: 100))
            }
            let summary = RTSSignpostEmitter.inputSummary(input, nodeType: .tool)
            #expect(summary.hasSuffix("…"))
            #expect(summary.utf8.count < RTSSignpostEmitter.inputSummaryLimit + 200)
        }
    }
}
