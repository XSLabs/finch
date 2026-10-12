// SPDX-License-Identifier: MIT OR Apache-2.0
// FeatureFlags.framework, Finch's: Swift's view of the system's feature flags. A flag
// names a domain and a feature, and is answered by os_feature_enabled
// (libsystem_featureflags, Finch's own), as Apple's is.

/// A feature flag, as a type naming its domain and feature.
public protocol FeatureFlagsKey {
  var domain: StaticString { get }
  var feature: StaticString { get }
}

@_silgen_name("_os_feature_enabled_impl")
private func _osFeatureEnabled(_ domain: UnsafePointer<CChar>, _ feature: UnsafePointer<CChar>) -> Bool

/// Whether the flag is on.
public func isFeatureEnabled(_ flag: FeatureFlagsKey) -> Bool {
  let domain = flag.domain, feature = flag.feature
  return domain.withUTF8Buffer { d in
    feature.withUTF8Buffer { f in
      // (StaticStrings' buffers aren't terminated: copy each with its terminator)
      let dc = Array(d.map { CChar(bitPattern: $0) }) + [0]
      let fc = Array(f.map { CChar(bitPattern: $0) }) + [0]
      return dc.withUnsafeBufferPointer { dp in
        fc.withUnsafeBufferPointer { fp in _osFeatureEnabled(dp.baseAddress!, fp.baseAddress!) }
      }
    }
  }
}
