#!/usr/bin/env ruby
# remove_info_plist_from_resources.rb
# Removes Info-Debug.plist from Copy Bundle Resources build phase
# Run with: ruby remove_info_plist_from_resources.rb

require 'xcodeproj'

project_path = 'anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj'
target_name  = 'AnkiVoice'

begin
  proj = Xcodeproj::Project.open(project_path)
  target = proj.targets.find { |t| t.name == target_name }
  
  unless target
    puts "ERROR: Target '#{target_name}' not found in project"
    exit 1
  end
  
  phase = target.resources_build_phase
  removed = false
  
  phase.files.each do |file_ref|
    if file_ref.file_ref && file_ref.file_ref.path&.end_with?('Info-Debug.plist')
      phase.remove_file_reference(file_ref.file_ref)
      removed = true
      puts "Removed #{file_ref.file_ref.path} from Copy Bundle Resources"
    end
  end
  
  if removed
    proj.save
    puts "✓ Successfully removed Info-Debug.plist from Copy Bundle Resources."
    puts "\nVerify Build Settings:"
    puts "  Debug → Info.plist File = AnkiVoice/Info-Debug.plist"
    puts "  Release → Info.plist File = AnkiVoice/Info.plist"
  else
    puts "Info-Debug.plist not found in Copy Bundle Resources (may already be removed)"
  end
rescue LoadError
  puts "ERROR: xcodeproj gem not installed."
  puts "Install with: gem install xcodeproj"
  exit 1
rescue => e
  puts "ERROR: #{e.message}"
  puts e.backtrace if ENV['DEBUG']
  exit 1
end

