//
//  ErrorReportCallSiteTests.swift
//  RailtracksSwiftTests
//

import Testing
import RailtownLogger
@testable import RailtracksSwift

@Suite struct ErrorReportCallSiteTests {
    /// The factory captured this line; the report must carry the same position.
    @Test func theRaiseSiteIsForwardedInRailtownLoggersShape() {
        let error = RTSError.missingInput("prompt")   // <- the line under test
        let expectedLine = #line - 1

        let callSite = error.railtownCallSite
        #expect(callSite.file == "RailtracksSwiftTests/ErrorReportCallSiteTests.swift")
        #expect(callSite.function == "theRaiseSiteIsForwardedInRailtownLoggersShape()")
        #expect(callSite.line == expectedLine)
    }

    /// `RTSFlow` only forwards a site for errors that recorded one; anything else
    /// must produce nil rather than a fabricated location.
    @Test func nonRailtracksErrorsCarryNoRaiseSite() {
        struct Other: Error {}
        #expect((Other() as Error as? RTSError)?.railtownCallSite == nil)
    }
}
