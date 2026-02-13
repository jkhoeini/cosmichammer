# Uncomment this line to define a global platform for your project
platform :osx, '15.0'

inhibit_all_warnings!

source 'https://github.com/CocoaPods/Specs.git'

project 'Hammerspoon', 'Profile' => :debug

target 'Hammerspoon' do
pod 'ASCIImage', '1.0.0'
pod 'CocoaLumberjack', '3.8.5'
pod 'CocoaAsyncSocket', '7.6.5'
pod 'CocoaHTTPServer', :git => 'https://github.com/Hammerspoon/CocoaHTTPServer.git'
pod 'PocketSocket/Client', '1.0.1'
pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '8.57.3'
pod 'Sparkle', '2.6.4', :configurations => ['Release']
pod 'MIKMIDI', '1.7.1'
pod 'SocketRocket', '0.7.1'
pod 'ORSSerialPort', '2.1.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
   puts "Enabling assertions in #{target.name}"

   target.build_configurations.each do |config|
     config.build_settings['ENABLE_NS_ASSERTIONS'] = 'YES'
    if config.build_settings['MACOSX_DEPLOYMENT_TARGET'].to_f < 15.0
        config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
      end
    end

    puts "Configuring Sentry"
   target.build_configurations.each do |config|
     if target.name == 'Sentry'
       config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)', 'SENTRY_NO_UIKIT=1']
     end
   end
  end
end
