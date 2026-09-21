#!/usr/bin/env ruby
# Creates local release metadata only; never uploads or changes system settings.
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'openssl'
require_relative 'release-metadata'

def capture!(*args)
  output, status = Open3.capture2e(*args)
  abort output unless status.success?
  output.strip
end

repo = ARGV.fetch(0, '')
abort 'Usage: ruby scripts/prepare-release.rb OWNER/REPO [archive.zip]' unless
  ARGV.length.between?(1, 2) && repo.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
root = File.expand_path('..', __dir__)
version = capture!('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', "#{root}/Info.plist")
metadata = ReleaseMetadata.new(version, ENV.fetch('GKSDUD_RELEASE_TAG', "v#{version}"))
filename = metadata.filename
archive = File.expand_path(ARGV[1] || "#{root}/outputs/#{filename}")
abort "Missing archive: #{archive}" unless File.file?(archive)
abort "Release asset must be named #{filename}" unless File.basename(archive) == filename
certificate = "#{root}/signing/local-certificate.pem"
abort 'Missing publisher public certificate' unless File.file?(certificate)
fingerprint = OpenSSL::Digest::SHA1.hexdigest(OpenSSL::X509::Certificate.new(File.read(certificate)).to_der)
requirement = "identifier \"io.gksdud.inputswitch\" and certificate leaf = H\"#{fingerprint}\""

Dir.mktmpdir('gksdud-release-') do |stage|
  # Validate ZIP paths before extracting an explicitly selected build artifact.
  entries = capture!('/usr/bin/unzip', '-Z1', archive).lines.map(&:strip)
  abort 'Unexpected ZIP contents' unless entries.all? { |p| p.start_with?('gksdud.app/') && !p.split('/').include?('..') }
  capture!('/usr/bin/ditto', '-x', '-k', archive, stage)
  app = "#{stage}/gksdud.app"
  license = "#{app}/Contents/Resources/LICENSE"
  abort 'Archive must include the current LICENSE' unless File.file?(license) &&
    File.binread(license) == File.binread("#{root}/LICENSE")
  capture!('/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', '-R', "=#{requirement}", app)
  %w[CFBundleShortVersionString CFBundleVersion CFBundleIdentifier].each do |key|
    expected = capture!('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", "#{root}/Info.plist")
    actual = capture!('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", "#{app}/Contents/Info.plist")
    abort "Archive #{key} does not match source" unless expected == actual
  end
  arches = capture!('/usr/bin/lipo', '-archs', "#{app}/Contents/MacOS/gksdud").split
  abort 'Expected arm64 + x86_64' unless arches.sort == %w[arm64 x86_64]
end

sha256 = Digest::SHA256.file(archive).hexdigest
output = "#{root}/outputs/release-#{metadata.asset_version}"
FileUtils.mkdir_p(output)
File.write("#{output}/SHA256SUMS", "#{sha256}  #{filename}\n")
# Prereleases are direct downloads only; never prepare a stable Homebrew cask.
unless metadata.prerelease?
  File.write("#{output}/gksdud.rb", <<~CASK)
  cask "gksdud" do
    version "#{version}"
    sha256 "#{sha256}"

    url "https://github.com/#{repo}/releases/download/v\#{version}/gksdud-\#{version}-macos-universal.zip"
    name "gksdud"
    desc "Korean-English input switching from the menu bar"
    homepage "https://github.com/#{repo}"

    depends_on macos: :ventura

    app "gksdud.app"

    uninstall quit: "io.gksdud.inputswitch"

    caveats <<~EOS
      This build is self-signed and is not notarized by Apple.
      macOS may block its first launch. No security settings are changed by this cask.
      Accessibility permission is required for switching on key press.
      If Homebrew cannot quit gksdud, quit it normally to restore keyboard settings.
    EOS
  end
CASK
end
puts "Verified archive. Metadata: #{output}"
puts 'Not published. Test Gatekeeper, fresh installation, and upgrades on a separate Mac before release.'
