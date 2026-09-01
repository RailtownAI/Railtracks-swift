//
//  RTSErrorReportProperty.swift
//  RailtracksSwift
//

/// Keys for the context RailtracksSwift attaches to error reports uploaded to
/// Conductr.
///
/// Declared here rather than written inline at each call site: RailtownLogger
/// passes the dictionary straight through to the wire, so these names are part
/// of what RailtracksSwift publishes and belong in one place.
enum RTSErrorReportProperty {
    /// The RailtracksSwift version that produced the failing run.
    static let railtracksVersion = "RailtracksVersion"
}
