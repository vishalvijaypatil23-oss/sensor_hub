#
# CocoaPods fallback. Flutter 3.47 uses the Swift package in sensor_hub/ when
# Swift Package Manager is enabled; both point at the same sources.
#
Pod::Spec.new do |s|
  s.name             = 'sensor_hub'
  s.version          = '0.1.0'
  s.summary          = 'High-rate sensor bridge with a custom binary codec and native backpressure.'
  s.description      = <<-DESC
High-rate sensor bridge with a custom binary codec and native backpressure.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'sensor_hub/Sources/sensor_hub/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {'sensor_hub_privacy' => ['sensor_hub/Sources/sensor_hub/PrivacyInfo.xcprivacy']}
end
