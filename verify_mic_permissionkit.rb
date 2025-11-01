#!/usr/bin/env ruby
# Usage:
#   ruby verify_mic_permissionkit.rb "<path/to/YourProject.xcodeproj>" "AppTargetName" "FrameworkTargetName"
# Example:
#   ruby verify_mic_permissionkit.rb "AnkiVoice/AnkiVoice.xcodeproj" "AnkiVoice" "MicPermissionKit"

require 'xcodeproj'
require 'pathname'

proj_path   = ARGV[0] || abort("ERROR: pass .xcodeproj path\n")
app_name    = ARGV[1] || "AnkiVoice"
fw_name     = ARGV[2] || "MicPermissionKit"

unless File.directory?(proj_path) && proj_path.end_with?('.xcodeproj')
  abort("ERROR: not an .xcodeproj folder: #{proj_path}")
end

proj = Xcodeproj::Project.open(proj_path)
src_root = Pathname.new(proj_path).dirname.expand_path
SRC_DIR_NAME = "AnkiVoice"
FW_NAME = fw_name

def ok(msg)   puts "✅  #{msg}" end
def warn(msg) puts "⚠️  #{msg}" end
def bad(msg)  puts "❌  #{msg}" end

puts "Inspecting project: #{proj_path}"
puts " App target: #{app_name}"
puts " Framework target: #{fw_name}"
puts "-"*70

app_t = proj.targets.find { |t| t.name == app_name }
fw_t  = proj.targets.find { |t| t.name == fw_name }

if app_t then ok("Found app target '#{app_name}'") else bad("Missing app target '#{app_name}'") ; exit 1 end
if fw_t  then ok("Found framework target '#{fw_name}'") else bad("Missing framework target '#{fw_name}'") ; exit 1 end

# ------- Helpers -------
def find_build_phase(target, klass)
  target.build_phases.find { |p| p.is_a?(klass) }
end

def find_copy_files_phase(target, name:)
  target.copy_files_build_phases.find { |p| p.name == name }
end

def has_target_dependency?(app_t, dep_t)
  app_t.dependencies.any? { |d| d.target == dep_t }
end

def file_in_phase?(phase, name_contains:)
  return false unless phase
  phase.files.any? { |pf| pf.file_ref && pf.file_ref.display_name && pf.file_ref.display_name.include?(name_contains) }
end

def find_phase_file(phase, name_contains:)
  return nil unless phase
  phase.files.find { |pf| pf.file_ref && pf.file_ref.display_name.include?(name_contains) }
end

def public_header?(headers_phase, header_name)
  pf = find_phase_file(headers_phase, name_contains: header_name)
  return false unless pf
  attrs = pf.settings && pf.settings['ATTRIBUTES'] || []
  attrs.include?('Public')
end

def code_sign_on_copy?(copy_phase, item_name)
  pf = find_phase_file(copy_phase, name_contains: item_name)
  return false unless pf
  attrs = pf.settings && pf.settings['ATTRIBUTES'] || []
  attrs.include?('CodeSignOnCopy')
end

# ------- App target checks -------
puts "\n[App Target: #{app_name}]"

dep_ok = has_target_dependency?(app_t, fw_t)
dep_ok ? ok("Target Dependencies includes #{fw_name}") :
         bad("Add #{fw_name} to Target Dependencies")

link_phase = find_build_phase(app_t, Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
link_ok = file_in_phase?(link_phase, name_contains: "#{fw_name}.framework")
link_ok ? ok("Link Binary With Libraries includes #{fw_name}.framework") :
          bad("Add #{fw_name}.framework to Link Binary With Libraries")

embed_phase = find_copy_files_phase(app_t, name: 'Embed Frameworks')
if embed_phase
  embed_ok  = file_in_phase?(embed_phase, name_contains: "#{fw_name}.framework")
  sign_ok   = code_sign_on_copy?(embed_phase, "#{fw_name}.framework")
  embed_ok ? ok("Embed Frameworks contains #{fw_name}.framework") :
             bad("Add #{fw_name}.framework to Embed Frameworks")
  sign_ok  ? ok("Embed Frameworks has Code Sign On Copy enabled") :
             bad("Enable Code Sign On Copy for #{fw_name}.framework in Embed Frameworks")
else
  bad("No 'Embed Frameworks' copy phase found — add one and include #{fw_name}.framework with Code Sign On Copy")
end

# ------- Framework target checks -------
puts "\n[Framework Target: #{fw_name}]"

# Sources
sources_phase = find_build_phase(fw_t, Xcodeproj::Project::Object::PBXSourcesBuildPhase)
m_ok = file_in_phase?(sources_phase, name_contains: 'MicPermissionShim.m')
m_ok ? ok("Compile Sources contains MicPermissionShim.m") :
       bad("Add MicPermissionShim.m to Compile Sources")

# Headers
headers_phase = find_build_phase(fw_t, Xcodeproj::Project::Object::PBXHeadersBuildPhase)
if headers_phase
  kit_pub = public_header?(headers_phase, 'MicPermissionKit.h')
  shim_pub = public_header?(headers_phase, 'MicPermissionShim.h')

  kit_pub  ? ok("Headers: MicPermissionKit.h is Public") :
             bad("Set MicPermissionKit.h to Public in Headers phase")
  shim_pub ? ok("Headers: MicPermissionShim.h is Public") :
             bad("Set MicPermissionShim.h to Public in Headers phase")
else
  bad("No Headers build phase on framework target")
end

# Build settings (framework)
fw_cfgs = fw_t.build_configurations
def val(cfgs, key)
  cfgs.map { |c| [c.name, c.build_settings[key]] }.to_h
end

defines = val(fw_cfgs, 'DEFINES_MODULE')
skip    = val(fw_cfgs, 'SKIP_INSTALL')
mod     = val(fw_cfgs, 'PRODUCT_MODULE_NAME')

puts "\n[Framework Build Settings]"
defines.each { |cfg,v| (v.to_s == 'YES') ? ok("#{cfg}: DEFINES_MODULE = YES") : bad("#{cfg}: DEFINES_MODULE should be YES (is #{v.inspect})") }
skip.each    { |cfg,v| (v.to_s == 'NO')  ? ok("#{cfg}: SKIP_INSTALL = NO")    : bad("#{cfg}: SKIP_INSTALL should be NO (is #{v.inspect})") }
mod.each     { |cfg,v| (v.to_s == fw_name) ? ok("#{cfg}: PRODUCT_MODULE_NAME = #{fw_name}") : bad("#{cfg}: PRODUCT_MODULE_NAME should be #{fw_name} (is #{v.inspect})") }

# File existence
puts "\n[File Existence]"
expected = %w[MicPermissionKit.h MicPermissionShim.h MicPermissionShim.m]
expected.each do |fname|
  # Search through all file references in the project
  hit = proj.files.find { |fr| fr && fr.display_name == fname }
  path = nil
  if hit
    if hit.respond_to?(:real_path) && hit.real_path && !hit.real_path.to_s.empty?
      path = Pathname.new(hit.real_path.to_s)
    elsif hit.path
      # Try resolving path relative to project root
      possible_paths = [
        src_root + hit.path,
        src_root + SRC_DIR_NAME + fw_name + fname,
        src_root + SRC_DIR_NAME + fw_name + hit.path
      ]
      possible_paths.each do |p|
        if File.exist?(p.to_s)
          path = p.expand_path
          break
        end
      end
    end
  end
  # Also check common framework directory locations
  if !path || !File.exist?(path.to_s)
    fw_dir = src_root + SRC_DIR_NAME + fw_name
    alt_path = fw_dir + fname
    if File.exist?(alt_path.to_s)
      path = alt_path.expand_path
    end
  end
  if path && File.exist?(path.to_s)
    ok("#{fname} → #{path}")
  else
    # Last resort: search for file anywhere
    found_files = Dir.glob("#{src_root}/**/#{fname}")
    if found_files.any?
      ok("#{fname} → #{found_files.first}")
    else
      bad("#{fname} not found on disk via project reference")
    end
  end
end

puts "\nDone."

