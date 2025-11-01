#!/usr/bin/env ruby
require "xcodeproj"

PROJECT_PATH = "anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj"
FRAMEWORK_NAME = "MicPermissionKit"
SRC_DIR_NAME = "AnkiVoice"
PROJECT_DIR = File.dirname(PROJECT_PATH)  # anki-voice-ios/AnkiVoice
FRAMEWORK_DIR = File.join(PROJECT_DIR, SRC_DIR_NAME, FRAMEWORK_NAME)  # AnkiVoice/MicPermissionKit

abort("❌ Project not found: #{PROJECT_PATH}") unless File.exist?(PROJECT_PATH)
abort("❌ Framework directory not found: #{FRAMEWORK_DIR}") unless File.directory?(FRAMEWORK_DIR)

proj = Xcodeproj::Project.open(PROJECT_PATH)

# Find the framework target
fw_target = proj.targets.find { |t| t.name == FRAMEWORK_NAME }
abort("❌ Framework target '#{FRAMEWORK_NAME}' not found") unless fw_target

# Get the absolute path to the framework source directory
framework_abs_path = File.expand_path(FRAMEWORK_DIR)
framework_relative_from_project = File.join("$(SRCROOT)", SRC_DIR_NAME, FRAMEWORK_NAME)

puts "▶ Framework directory: #{framework_abs_path}"
puts "▶ Adding to header search paths: #{framework_relative_from_project}"

# Add the framework directory to USER_HEADER_SEARCH_PATHS for both Debug and Release
%w(Debug Release).each do |cfg|
  settings = fw_target.build_settings(cfg)
  
  # Get existing paths
  existing_user_paths = settings["USER_HEADER_SEARCH_PATHS"] || []
  existing_user_paths = [existing_user_paths] unless existing_user_paths.is_a?(Array)
  existing_user_paths = existing_user_paths.dup
  
  # Get existing header paths
  existing_header_paths = settings["HEADER_SEARCH_PATHS"] || []
  existing_header_paths = [existing_header_paths] unless existing_header_paths.is_a?(Array)
  existing_header_paths = existing_header_paths.dup
  
  # Add framework directory (relative to SRCROOT)
  framework_path = framework_relative_from_project
  
  unless existing_user_paths.include?(framework_path)
    existing_user_paths << framework_path
    settings["USER_HEADER_SEARCH_PATHS"] = existing_user_paths
    puts "  ✅ Added to USER_HEADER_SEARCH_PATHS for #{cfg}"
  end
  
  # Also add recursive flag if needed
  unless existing_user_paths.include?("#{framework_path}/**")
    # Xcode will search recursively if we add the path
  end
  
  # Also ensure HEADER_SEARCH_PATHS includes it
  unless existing_header_paths.include?(framework_path)
    existing_header_paths << framework_path
    settings["HEADER_SEARCH_PATHS"] = existing_header_paths
    puts "  ✅ Added to HEADER_SEARCH_PATHS for #{cfg}"
  end
end

proj.save
puts "✅ Fixed header search paths for #{FRAMEWORK_NAME}"
puts "   The umbrella header should now find MicPermissionShim.h"

