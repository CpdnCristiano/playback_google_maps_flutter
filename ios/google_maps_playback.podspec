#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint replay_map_native.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'google_maps_playback'
  s.version          = '0.0.1'
  s.summary          = 'A high-performance Google Maps playback plugin for Flutter.'
  s.description      = <<-DESC
A high-performance Google Maps playback plugin for Flutter using native SDKs for smooth vehicle movement and trail rendering.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CPDN Tech' => 'cristiano@cpdntech.com.br' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'GoogleMaps', '>= 8.4', '< 11.0'
  s.static_framework = true
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES'}
  s.swift_version = '5.0'
end
