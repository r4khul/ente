Pod::Spec.new do |s|
  s.name             = 'ente_configuration'
  s.version          = '1.0.0'
  s.summary          = 'Shared configuration for Ente apps'
  s.description      = 'Read secure configuration while preserving Keychain errors.'
  s.homepage         = 'https://github.com/ente/ente'
  s.license          = { :type => 'AGPL-3.0-only' }
  s.author           = { 'Ente' => 'support@ente.com' }
  s.source           = { :path => '.' }
  s.source_files = 'ente_configuration/Sources/ente_configuration/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
