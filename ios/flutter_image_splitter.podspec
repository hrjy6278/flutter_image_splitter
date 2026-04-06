#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_image_splitter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_image_splitter'
  s.version          = '0.2.0'
  s.summary          = 'Splits tall images into memory-efficient chunks using native bitmap decoders.'
  s.description      = <<-DESC
A Flutter plugin that splits tall/long images into chunks below Flutter's
~8192px GPU texture limit. Uses CGImageSource on iOS for region-based
decoding without loading the full image into memory.
                       DESC
  s.homepage         = 'https://github.com/hrjy6278/image_splitter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'hrjy6278' => 'noreply@hrjy6278.dev' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
