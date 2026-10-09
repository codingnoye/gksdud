#!/usr/bin/env ruby
# Creates local release metadata only; never uploads or changes system settings.
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'release-metadata'

def capture!(*args)
  output, status = Open3.capture2e(*args)
  abort output unless status.success?
  output.strip
end

repo = ARGV.fetch(0, '')
abort 'Usage: ruby scripts/prepare-release.rb OWNER/REPO [archive.zip [self-signed archive.zip]]' unless
  ARGV.length.between?(1, 3) && repo.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
root = File.expand_path(ENV.fetch('GKSDUD_SOURCE_ROOT', File.expand_path('..', __dir__)))
version = ENV.fetch('GKSDUD_APP_VERSION') { capture!('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', "#{root}/Info.plist") }
metadata = ReleaseMetadata.new(version, ENV.fetch('GKSDUD_RELEASE_TAG', "v#{version}"))
signing = File.expand_path('../signing', __dir__)
team = File.read("#{signing}/developer-team-id").strip
abort 'Invalid Developer ID team' unless team.match?(/\A[A-Z0-9]{10}\z/)
developer_id = "anchor apple generic and identifier \"#{metadata.identifier}\" and certificate 1[field.1.2.840.113635.100.6.2.6]" \
  " and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"#{team}\""
self_signed = File.read("#{signing}/release-certificate.sha1").strip
abort 'Invalid self-signed certificate fingerprint' unless self_signed.match?(/\A[0-9A-F]{40}\z/)
archives = { metadata.filename => [ARGV[1], developer_id] }
archives[metadata.self_signed_filename] = [ARGV[2], "identifier \"#{metadata.identifier}\" and certificate leaf = H\"#{self_signed}\""] if
  metadata.self_signed_filename

sums = archives.map do |filename, (path, requirement)|
  archive = File.expand_path(path || "#{root}/outputs/#{filename}")
  abort "Missing archive: #{archive}" unless File.file?(archive)
  abort "Release asset must be named #{filename}" unless File.basename(archive) == filename
  Dir.mktmpdir('gksdud-release-') do |stage|
    # Validate ZIP paths before extracting an explicitly selected build artifact.
    entries = capture!('/usr/bin/unzip', '-Z1', archive).lines.map(&:strip)
    abort 'Unexpected ZIP contents' unless entries.all? { |p| p.start_with?("#{metadata.app}.app/") && !p.split('/').include?('..') }
    capture!('/usr/bin/ditto', '-x', '-k', archive, stage)
    app = "#{stage}/#{metadata.app}.app"
    license = "#{app}/Contents/Resources/LICENSE"
    abort 'Archive must include the current LICENSE' unless File.file?(license) &&
      File.binread(license) == File.binread("#{root}/LICENSE")
    capture!('/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', '-R', "=#{requirement}", app)
    # Only the Developer ID app is notarized; the self-signed copy reaches old apps through their updater, not a download.
    if requirement == developer_id
      capture!('/usr/bin/xcrun', 'stapler', 'validate', app)
      capture!('/usr/sbin/spctl', '--assess', '--type', 'execute', app)
    end
    %w[CFBundleShortVersionString CFBundleVersion CFBundleIdentifier].each do |key|
      expected = capture!('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", "#{root}/Info.plist")
      expected = version if key == 'CFBundleShortVersionString'
      expected = metadata.identifier if key == 'CFBundleIdentifier'
      actual = capture!('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", "#{app}/Contents/Info.plist")
      abort "Archive #{key} does not match source" unless expected == actual
    end
    arches = capture!('/usr/bin/lipo', '-archs', "#{app}/Contents/MacOS/gksdud").split
    abort 'Expected arm64 + x86_64' unless arches.sort == %w[arm64 x86_64]
  end
  "#{Digest::SHA256.file(archive).hexdigest}  #{filename}\n"
end

sha256 = sums.first.split.first
output = "#{root}/outputs/release-#{metadata.asset_version}"
FileUtils.mkdir_p(output)
File.write("#{output}/SHA256SUMS", sums.join)
# Prereleases are direct downloads only; never prepare a stable Homebrew cask.
unless metadata.prerelease?
  File.write("#{output}/gksdud.rb", <<~CASK)
  cask "gksdud" do
    version "#{version}"
    sha256 "#{sha256}"

    url "https://github.com/#{repo}/releases/download/v\#{version}/gksdud-\#{version}.zip"
    name "gksdud"
    desc "Korean-English input switching from the menu bar"
    homepage "https://github.com/#{repo}"

    depends_on macos: :ventura

    app "gksdud.app"

    uninstall quit: "io.gksdud.inputswitch"

    caveats <<~EOS
  #{ReleaseMetadata::SELF_SIGNED_COPY ? "    Updating from 1.8.0 or earlier asks for Accessibility once more, as the app is now signed by Apple.\n" : ''}    Accessibility permission is required for switching on key press.
      If Homebrew cannot quit gksdud, quit it normally to restore keyboard settings.
    EOS
  end
CASK
end
puts "Verified #{archives.keys.join(' and ')}. Metadata: #{output}"
puts 'Not published. Test Gatekeeper, fresh installation, and upgrades on a separate Mac before release.'
