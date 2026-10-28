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
abort 'Usage: ruby scripts/prepare-release.rb OWNER/REPO [release asset ...]' unless
  ARGV.length.between?(1, 4) && repo.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
root = File.expand_path(ENV.fetch('GKSDUD_SOURCE_ROOT', File.expand_path('..', __dir__)))
version = ENV.fetch('GKSDUD_APP_VERSION') { capture!('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', "#{root}/Info.plist") }
metadata = ReleaseMetadata.new(version, ENV.fetch('GKSDUD_RELEASE_TAG', "v#{version}"))
signing = File.expand_path('../signing', __dir__)
team = File.read("#{signing}/developer-team-id").strip
abort 'Invalid Developer ID team' unless team.match?(/\A[A-Z0-9]{10}\z/)
developer_id_of = lambda do |identifier|
  "anchor apple generic and identifier \"#{identifier}\" and certificate 1[field.1.2.840.113635.100.6.2.6]" \
    " and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"#{team}\""
end
developer_id = developer_id_of.call(metadata.identifier)
self_signed = File.read("#{signing}/release-certificate.sha1").strip
abort 'Invalid self-signed certificate fingerprint' unless self_signed.match?(/\A[0-9A-F]{40}\z/)
archives = { metadata.filename => developer_id }
archives[metadata.self_signed_filename] = "identifier \"#{metadata.identifier}\" and certificate leaf = H\"#{self_signed}\"" if
  metadata.self_signed_filename
# Given assets are a published release's, which has the disk image only from the version that added it.
given = ARGV.drop(1).to_h { |path| [File.basename(path), File.expand_path(path)] }
unexpected = given.keys - archives.keys - [metadata.dmg_filename]
abort "Unexpected release asset: #{unexpected.join(', ')}" unless unexpected.empty?
path_of = ->(name) { given.empty? ? "#{root}/outputs/#{name}" : given[name] }
# stapler asks Apple's servers, which now and then drop the connection.
validate_ticket = lambda do |path|
  3.times do |attempt|
    return if Open3.capture2e('/usr/bin/xcrun', 'stapler', 'validate', path).last.success?
    sleep 3 * (attempt + 1)
  end
  capture!('/usr/bin/xcrun', 'stapler', 'validate', path)
end
code_hash = ->(app) { capture!('/usr/bin/codesign', '-d', '--verbose=4', app)[/^CDHash=(\h+)$/, 1] or abort 'No CDHash' }
cdhash = nil

sums = archives.map do |filename, requirement|
  archive = path_of.call(filename)
  abort "Missing archive: #{filename}" unless archive && File.file?(archive)
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
      validate_ticket.call(app)
      capture!('/usr/sbin/spctl', '--assess', '--type', 'execute', app)
    end
    %w[CFBundleShortVersionString CFBundleVersion CFBundleIdentifier].each do |key|
      expected = capture!('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", "#{root}/Info.plist")
      expected = version if key == 'CFBundleShortVersionString'
      expected = metadata.identifier if key == 'CFBundleIdentifier'
      actual = capture!('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", "#{app}/Contents/Info.plist")
      abort "Archive #{key} does not match source" unless expected == actual
    end
    # A canary shows its name as gksdud-CAN; stable releases and prereleases carry no channel, and a local build never ships.
    channel, = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', 'Print :GKSDUDChannel', "#{app}/Contents/Info.plist")
    abort 'Archive is not a build of its channel' unless (metadata.channel == 'canary' ? channel.strip == 'canary' : channel.include?('Does Not Exist'))
    arches = capture!('/usr/bin/lipo', '-archs', "#{app}/Contents/MacOS/gksdud").split
    abort 'Expected arm64 + x86_64' unless arches.sort == %w[arm64 x86_64]
    cdhash = code_hash.call(app) if requirement == developer_id
  end
  "#{Digest::SHA256.file(archive).hexdigest}  #{filename}\n"
end

# The disk image holds the same notarized app as the archive, beside a link to Applications, and its window layout.
dmg = path_of.call(metadata.dmg_filename)
if dmg || given.empty?
  abort "Missing disk image: #{metadata.dmg_filename}" unless dmg && File.file?(dmg)
  capture!('/usr/bin/codesign', '--verify', '--strict', '-R', "=#{developer_id_of.call("#{metadata.identifier}.dmg")}", dmg)
  validate_ticket.call(dmg)
  capture!('/usr/sbin/spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)
  Dir.mktmpdir('gksdud-dmg-') do |stage|
    volume = "#{stage}/volume"
    begin
      # hdiutil now and then finds the image busy.
      attach = ['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', volume, dmg]
      3.times do |attempt|
        break if Open3.capture2e(*attach).last.success?
        sleep 3 * (attempt + 1)
      end
      capture!(*attach) unless File.directory?("#{volume}/#{metadata.app}.app")
      abort 'Unexpected disk image contents' unless
        Dir.children(volume).sort == ['.DS_Store', '.VolumeIcon.icns', '.background.tiff', 'Applications', "#{metadata.app}.app"] &&
        File.symlink?("#{volume}/Applications") && File.readlink("#{volume}/Applications") == '/Applications'
      app = "#{volume}/#{metadata.app}.app"
      capture!('/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', '-R', "=#{developer_id}", app)
      validate_ticket.call(app)
      abort 'Disk image app differs from the archive' unless code_hash.call(app) == cdhash
    ensure
      system('/usr/bin/hdiutil', 'detach', '-quiet', volume) || system('/usr/bin/hdiutil', 'detach', '-force', '-quiet', volume)
    end
  end
  sums << "#{Digest::SHA256.file(dmg).hexdigest}  #{metadata.dmg_filename}\n"
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
puts "Verified #{(archives.keys + (dmg ? [metadata.dmg_filename] : [])).join(', ')}. Metadata: #{output}"
puts 'Not published. Test Gatekeeper, fresh installation, and upgrades on a separate Mac before release.'
