#!/usr/bin/env ruby
require "xcodeproj"
require "fileutils"

# --- paths you actually have ---
PROJECT_PATH   = "anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj"
APP_TARGET_FALLBACK = "AnkiVoice"
SRC_DIR_NAME   = "AnkiVoice"               # folder next to .xcodeproj that holds sources
FRAMEWORK_NAME = "MicPermissionKit"

# --- derived ---
PROJECT_DIR    = File.dirname(PROJECT_PATH)               # anki-voice-ios/AnkiVoice
SRC_DIR        = File.join(PROJECT_DIR, SRC_DIR_NAME)     # .../AnkiVoice/AnkiVoice
FRAMEWORK_DIR  = File.join(SRC_DIR, FRAMEWORK_NAME)       # .../AnkiVoice/AnkiVoice/MicPermissionKit

FileUtils.mkdir_p(FRAMEWORK_DIR)

# Ensure required files exist
shim_h = File.join(FRAMEWORK_DIR, "MicPermissionShim.h")
shim_m = File.join(FRAMEWORK_DIR, "MicPermissionShim.m")
umbrella_h = File.join(FRAMEWORK_DIR, "#{FRAMEWORK_NAME}.h")

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
          if (completion) { dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); }); }
      }];
  #pragma clang diagnostic pop
  }
  @end
M

UMBRELLA_SRC = <<~U
  #import <Foundation/Foundation.h>
  // Public umbrella header for MicPermissionKit — import all public headers here.
  #import <MicPermissionKit/MicPermissionShim.h>
U

File.write(shim_h, HDR_SRC) unless File.exist?(shim_h)
File.write(shim_m, M_SRC)   unless File.exist?(shim_m)
File.write(umbrella_h, UMBRELLA_SRC) unless File.exist?(umbrella_h)

# Open the project
proj = Xcodeproj::Project.open(PROJECT_PATH)

# Find app target
app_target = proj.targets.find { |t| t.product_type == "com.apple.product-type.application" && t.platform_name == :ios } ||
             proj.targets.find { |t| t.name == APP_TARGET_FALLBACK }
abort("❌ Could not find iOS app target") unless app_target

# Find or create framework target
fw_target = proj.targets.find { |t| t.name == FRAMEWORK_NAME }
unless fw_target
  fw_target = proj.new_target(:framework, FRAMEWORK_NAME, :ios, app_target.deployment_target || "15.0", nil, :objc)
end

# Ensure groups: <main> / AnkiVoice / MicPermissionKit
def find_group_by_name(project, name)
  project.groups.each do |group|
    return group if (group.respond_to?(:name) && group.name == name) ||
                    (group.respond_to?(:path) && group.path == name)
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
  src_group = proj.main_group.new_group(SRC_DIR_NAME, SRC_DIR_NAME)
end
if src_group.respond_to?(:set_source_tree)
  src_group.set_source_tree("<group>")
  src_group.set_path(SRC_DIR_NAME) if src_group.respond_to?(:set_path)
end

fw_group = find_group_by_name(proj, FRAMEWORK_NAME)
unless fw_group
  fw_group = src_group.new_group(FRAMEWORK_NAME, FRAMEWORK_NAME)
end
if fw_group.respond_to?(:set_source_tree)
  fw_group.set_source_tree("<group>")
  fw_group.set_path(FRAMEWORK_NAME) if fw_group.respond_to?(:set_path)
end

# Remove any duplicate/bad file refs for these files
wanted_paths = ["MicPermissionShim.h","MicPermissionShim.m","#{FRAMEWORK_NAME}.h"]
proj.files.dup.each do |f|
  next unless f.path
  next unless wanted_paths.include?(File.basename(f.path))
  # if the parent group isn't our fw_group, drop it
  if f.respond_to?(:parent) && f.parent != fw_group
    f.remove_from_project
  end
end

# Create refs (filenames only, relative to fw_group)
shim_h_ref = fw_group.files.find { |f| f.path == "MicPermissionShim.h" } || fw_group.new_file("MicPermissionShim.h")
shim_m_ref = fw_group.files.find { |f| f.path == "MicPermissionShim.m" } || fw_group.new_file("MicPermissionShim.m")
umbrella_ref = fw_group.files.find { |f| f.path == "#{FRAMEWORK_NAME}.h" } || fw_group.new_file("#{FRAMEWORK_NAME}.h")

shim_h_ref.source_tree = "<group>"
shim_m_ref.source_tree = "<group>"
umbrella_ref.source_tree = "<group>"

# Make sure the .m is in Sources once
src_phase = fw_target.source_build_phase
src_phase.add_file_reference(shim_m_ref, true) unless src_phase.files.any? { |bf| bf.file_ref == shim_m_ref }

# Clean Headers phase: remove all existing entries for these headers
hdr_phase = fw_target.headers_build_phase
hdr_phase.files.dup.each do |bf|
  next unless bf.file_ref
  bn = File.basename(bf.file_ref.path.to_s)
  bf.remove_from_project if wanted_paths.include?(bn)
end

# Re-add headers: ONLY the umbrella is Public; the shim header is Project (non-Public)
umbrella_bf = hdr_phase.add_file_reference(umbrella_ref, true)
umbrella_bf.settings = { "ATTRIBUTES" => ["Public"] }

shim_bf = hdr_phase.add_file_reference(shim_h_ref, true)
shim_bf.settings = {} # default = Project (not Public/Private)

# Remove headers from any Copy Files phases (prevents duplicate CpHeader)
fw_target.copy_files_build_phases.each do |phase|
  phase.files.dup.each do |bf|
    next unless bf.file_ref
    bn = File.basename(bf.file_ref.path.to_s)
    bf.remove_from_project if wanted_paths.include?(bn)
  end
end

# Ensure module is defined and module name is correct
%w(Debug Release).each do |cfg|
  s = fw_target.build_settings(cfg)
  s["DEFINES_MODULE"] = "YES"
  s["PRODUCT_MODULE_NAME"] = FRAMEWORK_NAME
  # Optional but tidy:
  s["SKIP_INSTALL"] = "NO"
end

# Link + embed + dependency from app -> framework
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
if prod_ref && !copy_phase.files.any? { |bf| bf.file_ref == prod_ref }
  bf = copy_phase.add_file_reference(prod_ref, true)
  bf.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

proj.save
puts "✅ MicPermissionKit repaired: umbrella header added, duplicate header copies removed, module enabled, linked & embedded."

