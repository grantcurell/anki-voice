#!/usr/bin/env ruby
require "xcodeproj"
require "fileutils"

# ---- CONFIG you actually have ----
PROJECT_PATH   = "anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj"
APP_TARGET_NAME_FALLBACK = "AnkiVoice"
SRC_DIR_NAME   = "AnkiVoice"               # folder next to .xcodeproj that holds sources
FRAMEWORK_NAME = "MicPermissionKit"

# ---- Derived paths ----
PROJECT_DIR = File.dirname(PROJECT_PATH)   # anki-voice-ios/AnkiVoice
SRC_DIR     = File.join(PROJECT_DIR, SRC_DIR_NAME) # .../AnkiVoice/AnkiVoice
FRAMEWORK_DIR = File.join(SRC_DIR, FRAMEWORK_NAME) # .../AnkiVoice/AnkiVoice/MicPermissionKit

# Wrong legacy locations we clean up:
NESTED_BAD_DIR = File.join(SRC_DIR, SRC_DIR_NAME, FRAMEWORK_NAME) # .../AnkiVoice/AnkiVoice/AnkiVoice/MicPermissionKit
LEGACY_HDR     = File.join(SRC_DIR, "MicPermissionShim.h")        # .../AnkiVoice/AnkiVoice/MicPermissionShim.h
LEGACY_M       = File.join(SRC_DIR, "MicPermissionShim.m")

def say(s) puts "▶ #{s}" end
abort("No project at #{PROJECT_PATH}") unless File.exist?(PROJECT_PATH)

# 1) Make sure final directory exists
FileUtils.mkdir_p(FRAMEWORK_DIR)

# 2) Move files from any wrong places -> FRAMEWORK_DIR
def move_if_exists(src, dst_dir)
  return unless File.exist?(src)
  FileUtils.mv(src, File.join(dst_dir, File.basename(src)), force: true)
end

if File.directory?(NESTED_BAD_DIR)
  Dir[File.join(NESTED_BAD_DIR, "*")].each { |p| move_if_exists(p, FRAMEWORK_DIR) }
  Dir.rmdir(NESTED_BAD_DIR) rescue nil
end
move_if_exists(LEGACY_HDR, FRAMEWORK_DIR)
move_if_exists(LEGACY_M,   FRAMEWORK_DIR)

# 3) Ensure shim files exist (create if missing)
hdr_path  = File.join(FRAMEWORK_DIR, "MicPermissionShim.h")
m_path    = File.join(FRAMEWORK_DIR, "MicPermissionShim.m")

HDR_SRC = <<~H
  #import <Foundation/Foundation.h>
  typedef NS_ENUM(NSInteger, AVAudioRecordPermissionShim) {
      AVAudioRecordPermissionShimUndetermined = 1970168944,
      AVAudioRecordPermissionShimDenied       = 1684369017,
      AVAudioRecordPermissionShimGranted      = 1735552628
  };
  NS_SWIFT_NAME(MicPermissionShim)
  @interface MicPermissionShim : NSObject
  + (AVAudioRecordPermissionShim)recordPermission;
  + (void)requestRecordPermission:(void(^)(BOOL granted))completion;
  @end
H

M_SRC = <<~M
  #import "MicPermissionShim.h"
  @import AVFoundation;
  @implementation MicPermissionShim
  + (AVAudioRecordPermissionShim)recordPermission {
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wdeprecated-declarations"
      return (AVAudioRecordPermissionShim)[[AVAudioSession sharedInstance] recordPermission];
  #pragma clang diagnostic pop
  }
  + (void)requestRecordPermission:(void(^)(BOOL))completion {
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wdeprecated-declarations"
      [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted){
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
          }
      }];
  #pragma clang diagnostic pop
  }
  @end
M

File.write(hdr_path, HDR_SRC) unless File.exist?(hdr_path)
File.write(m_path,   M_SRC)   unless File.exist?(m_path)

# 4) Open project
proj = Xcodeproj::Project.open(PROJECT_PATH)

# 5) Find the iOS app target
app_target = proj.targets.find { |t|
  t.product_type == "com.apple.product-type.application" && t.platform_name == :ios
} || proj.targets.find { |t| t.name == APP_TARGET_NAME_FALLBACK }
abort("Could not find iOS app target") unless app_target

# 6) Fix group structure: main -> "AnkiVoice" -> "MicPermissionKit"
# Use a helper to find groups by name across the entire project
def find_group_by_name(project, name)
  project.groups.each do |group|
    return group if (group.respond_to?(:name) && group.name == name) ||
                    (group.respond_to?(:path) && group.path == name)
    # Recursively search children if it's a regular group
    if group.respond_to?(:children)
      found = group.children.find { |g| 
        (g.respond_to?(:name) && g.name == name) ||
        (g.respond_to?(:path) && g.path == name)
      }
      return found if found
    end
  end
  nil
end

src_group = find_group_by_name(proj, SRC_DIR_NAME)
unless src_group
  # Create as child of main group
  src_group = proj.main_group.new_group(SRC_DIR_NAME, SRC_DIR_NAME)
end

if src_group.respond_to?(:set_source_tree)
  src_group.set_source_tree("<group>")
  src_group.set_path(SRC_DIR_NAME) if src_group.respond_to?(:set_path)
end

fw_group = find_group_by_name(proj, FRAMEWORK_NAME)
unless fw_group
  # Create as child of src_group
  fw_group = src_group.new_group(FRAMEWORK_NAME, FRAMEWORK_NAME)
end

if fw_group.respond_to?(:set_source_tree)
  fw_group.set_source_tree("<group>")
  fw_group.set_path(FRAMEWORK_NAME) if fw_group.respond_to?(:set_path)
end

# Drop any stale/bad refs that point to duplicated project segments
proj.files.dup.each do |f|
  next unless f.path
  if f.path.include?("anki-voice-ios/AnkiVoice/AnkiVoice/") || f.path.include?("AnkiVoice/AnkiVoice/")
    f.remove_from_project
  end
end

# 7) Add file refs RELATIVE to fw_group (filenames only)
hdr_ref = fw_group.files.find { |f| f.path == "MicPermissionShim.h" } || fw_group.new_file("MicPermissionShim.h")
m_ref   = fw_group.files.find { |f| f.path == "MicPermissionShim.m" } || fw_group.new_file("MicPermissionShim.m")
hdr_ref.source_tree = "<group>"
m_ref.source_tree   = "<group>"

# 8) Create/find the framework target
fw_target = proj.targets.find { |t| t.name == FRAMEWORK_NAME }
unless fw_target
  fw_target = proj.new_target(:framework, FRAMEWORK_NAME, :ios, app_target.deployment_target || "15.0", nil, :objc)
end

# 9) Ensure sources & headers phases are correct and Public header is marked
src_phase = fw_target.source_build_phase
src_phase.add_file_reference(m_ref, true) unless src_phase.files.any? { |bf| bf.file_ref == m_ref }

hdr_phase = fw_target.headers_build_phase
hdr_bf = hdr_phase.files.find { |bf| bf.file_ref == hdr_ref } || hdr_phase.add_file_reference(hdr_ref, true)
hdr_bf.settings ||= {}
hdr_bf.settings["ATTRIBUTES"] = ["Public"]

# 10) Enable module output for the framework (usually default, but be explicit)
fw_target.build_settings("Debug")["DEFINES_MODULE"]  = "YES"
fw_target.build_settings("Release")["DEFINES_MODULE"] = "YES"
fw_target.build_settings("Debug")["PRODUCT_MODULE_NAME"]  = FRAMEWORK_NAME
fw_target.build_settings("Release")["PRODUCT_MODULE_NAME"] = FRAMEWORK_NAME

# 11) Link + embed framework in the app, and enforce build order
frameworks_phase = app_target.frameworks_build_phase
prod_ref = fw_target.product_reference
if prod_ref && !frameworks_phase.files.any? { |bf| bf.file_ref == prod_ref }
  frameworks_phase.add_file_reference(prod_ref, true)
end

app_target.add_dependency(fw_target) \
  unless app_target.dependencies.any? { |d| d.target == fw_target }

copy_phase = app_target.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :frameworks }
unless copy_phase
  copy_phase = proj.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  copy_phase.name = "Embed Frameworks"
  copy_phase.symbol_dst_subfolder_spec = :frameworks
  app_target.build_phases << copy_phase
end
prod_ref = fw_target.product_reference
unless copy_phase.files.any? { |bf| bf.file_ref == prod_ref }
  bf = copy_phase.add_file_reference(prod_ref, true)
  bf.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

proj.save
puts "✅ Fixed paths and linkage. Expect files at PROJECT_DIR/#{SRC_DIR_NAME}/#{FRAMEWORK_NAME}/MicPermissionShim.{h,m} and a buildable module."

