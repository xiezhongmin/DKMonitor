#
# Be sure to run `pod lib lint DKAPMMonitor.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'DKMonitor'
  s.version          = '0.0.1'
  s.summary          = 'A short description of DKMonitor.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC

  s.homepage         = 'https://github.com/xiezhongmin/DKMonitor'
  # s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'git' => '364101515@qq.com' }
  s.source           = { :git => 'https://github.com/xiezhongmin/DKMonitor.git', :tag => s.version.to_s }

  s.ios.deployment_target = '9.0'

  s.source_files = 'Modules/**/Classes/**/**/*.{h,m}'

  s.public_header_files = 'Modules/**/Classes/**/**/*.{h}'

  s.subspec 'DKAPMMonitor' do |sp|
      sp.source_files = 'Modules/DKAPMMonitor/Classes/**/**/*.{h,m}'
      sp.public_header_files = 'Modules/DKAPMMonitor/Classes/**/**/*.{h}'
  end

  s.subspec 'DKStackBacktrack' do |sp|
      sp.source_files = 'Modules/DKStackBacktrack/Classes/**/**/*.{h,m}'
      sp.public_header_files = 'Modules/DKStackBacktrack/Classes/**/**/*.{h}'
  end
  
  s.frameworks = 'UIKit'
  
  s.dependency 'DKKit'
end
