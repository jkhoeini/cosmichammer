# Uncomment this line to define a global platform for your project
platform :osx, '15.0'

inhibit_all_warnings!

source 'https://github.com/CocoaPods/Specs.git'

project 'Hammerspoon', 'Profile' => :debug

target 'Hammerspoon' do
pod 'ASCIImage', '1.0.0'
pod 'MIKMIDI', '1.7.1'
pod 'SocketRocket', '0.7.1'
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


  end
end
