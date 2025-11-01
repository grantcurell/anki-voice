#!/usr/bin/env ruby
require "xcodeproj"

PROJECT_PATH = "anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj"
FRAMEWORK_NAME = "MicPermissionKit"
SRC_GROUP_NAME = "AnkiVoice"

proj = Xcodeproj::Project.open(PROJECT_PATH)

# Find all file references with bad paths and fix them
fixed_count = 0
proj.files.each do |file_ref|
  next unless file_ref.path
  path_str = file_ref.path.to_s
  
  # Look for files with duplicate path segments
  if path_str.include?("anki-voice-ios/AnkiVoice/AnkiVoice/#{FRAMEWORK_NAME}/MicPermissionShim")
    puts "Found bad path: #{path_str}"
    
    # Extract just the filename
    basename = File.basename(path_str)
    
    # Set to just the filename with group source tree
    file_ref.path = basename
    file_ref.source_tree = "<group>"
    
    fixed_count += 1
    puts "  → Fixed to: #{basename} (relative to group)"
  end
end

# Find and fix any remaining file references that are duplicated
proj.targets.each do |target|
  next unless target.name == FRAMEWORK_NAME
  
  # Fix source files
  target.source_build_phase.files.each do |build_file|
    next unless build_file.file_ref&.path
    path = build_file.file_ref.path.to_s
    if path.include?("anki-voice-ios/AnkiVoice/AnkiVoice")
      basename = File.basename(path)
      build_file.file_ref.path = basename
      build_file.file_ref.source_tree = "<group>"
      fixed_count += 1
    end
  end
  
  # Fix header files
  target.headers_build_phase.files.each do |build_file|
    next unless build_file.file_ref&.path
    path = build_file.file_ref.path.to_s
    if path.include?("anki-voice-ios/AnkiVoice/AnkiVoice")
      basename = File.basename(path)
      build_file.file_ref.path = basename
      build_file.file_ref.source_tree = "<group>"
      fixed_count += 1
    end
  end
end

proj.save
puts "✅ Repaired #{fixed_count} file reference(s). Paths should now be relative to their groups."
puts "   Xcode will resolve: PROJECT_DIR/AnkiVoice/MicPermissionKit/<files>"
