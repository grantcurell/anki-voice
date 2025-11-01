#!/usr/bin/env ruby
require "xcodeproj"
require "fileutils"

PROJECT_PATH   = "anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj"
PROJECT_DIR    = File.dirname(PROJECT_PATH)          # anki-voice-ios/AnkiVoice
SRC_DIR_NAME   = "AnkiVoice"                         # folder next to .xcodeproj
SRC_DIR        = File.join(PROJECT_DIR, SRC_DIR_NAME)
FRAMEWORK_NAME = "MicPermissionKit"
FRAMEWORK_DIR  = File.join(SRC_DIR, FRAMEWORK_NAME)

def say(s) puts "▶ #{s}" end
abort("No project at #{PROJECT_PATH}") unless File.exist?(PROJECT_PATH)

# 1) Create files on disk in PROJECT_DIR/AnkiVoice/MicPermissionKit
FileUtils.mkdir_p(FRAMEWORK_DIR)

hdr_path  = File.join(FRAMEWORK_DIR, "MicPermissionShim.h")
impl_path = File.join(FRAMEWORK_DIR, "MicPermissionShim.m")

hdr_src = <<~H
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

impl_src = <<~M
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

File.write(hdr_path,  hdr_src) unless File.exist?(hdr_path)
File.write(impl_path, impl_src) unless File.exist?(impl_path)

# 2) Open project and create groups with correct relative paths
proj = Xcodeproj::Project.open(PROJECT_PATH)

src_group = proj.main_group.find_subpath(SRC_DIR_NAME, true)
src_group.set_source_tree("<group>")
src_group.set_path(SRC_DIR_NAME)                 # => PROJECT_DIR/AnkiVoice

fw_group = src_group.find_subpath(FRAMEWORK_NAME, true)
fw_group.set_source_tree("<group>")
fw_group.set_path(FRAMEWORK_NAME)                # => PROJECT_DIR/AnkiVoice/MicPermissionKit

# 3) Add file refs RELATIVE TO fw_group (filenames only)
hdr_ref = fw_group.files.find { |f| f.path == "MicPermissionShim.h" } || fw_group.new_file("MicPermissionShim.h")
src_ref = fw_group.files.find { |f| f.path == "MicPermissionShim.m" } || fw_group.new_file("MicPermissionShim.m")
hdr_ref.source_tree = "<group>"
src_ref.source_tree = "<group>"

# 4) Create/find framework target
app_target = proj.targets.find { |t| t.product_type == "com.apple.product-type.application" && t.platform_name == :ios }
fw_target  = proj.targets.find { |t| t.name == FRAMEWORK_NAME }
unless fw_target
  fw_target = proj.new_target(:framework, FRAMEWORK_NAME, :ios, app_target&.deployment_target || "15.0", nil, :objc)
end

# 5) Add sources, make header Public
src_phase = fw_target.source_build_phase
src_phase.add_file_reference(src_ref, true) unless src_phase.files.any? { |bf| bf.file_ref == src_ref }

hdr_phase = fw_target.headers_build_phase
hdr_bf = hdr_phase.files.find { |bf| bf.file_ref == hdr_ref } || hdr_phase.add_file_reference(hdr_ref, true)
hdr_bf.settings ||= {}
hdr_bf.settings["ATTRIBUTES"] = ["Public"]

# 6) Link and embed in app target
if app_target
  frameworks_phase = app_target.frameworks_build_phase
  product_ref = fw_target.product_reference
  if product_ref && !frameworks_phase.files.any? { |f| f.file_ref == product_ref }
    frameworks_phase.add_file_reference(product_ref, true)
  end

  unless app_target.dependencies.any? { |d| d.target == fw_target }
    app_target.add_dependency(fw_target)
  end

  copy_phase = app_target.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :frameworks } ||
               proj.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase).tap do |p|
                 p.name = "Embed Frameworks"
                 p.symbol_dst_subfolder_spec = :frameworks
                 app_target.build_phases << p
               end
  if product_ref && !copy_phase.files.any? { |f| f.file_ref == product_ref }
    bf = copy_phase.add_file_reference(product_ref, true)
    bf.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
  end
end

proj.save
puts "✅ Setup complete with correct relative paths."

