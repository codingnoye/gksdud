# Shared tag validation and asset naming for the release workflow and verifier.
class ReleaseMetadata
  # While apps up to 1.7.1 moved to Developer ID: they install only updates signed with the self-signed certificate, found
  # by the old archive name, so stable releases also carried that copy. Those left install the disk image by hand.
  SELF_SIGNED_COPY = false

  attr_reader :version, :tag, :channel

  # Every release is tagged vVERSION, and the fields tell the channel: three for stable, four for a prerelease numbered on the
  # stable release it follows (v2.3.0.1), five for a canary numbered on the prerelease or stable release before it
  # (v2.3.0.1.4, v2.3.1.0.2), so the next of either updates them.
  FORMS = { 'stable' => /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/,
            'pre' => /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.[1-9]\d*\z/,
            'canary' => /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.[1-9]\d*\z/ }.freeze

  def initialize(version, tag = "v#{version}")
    @channel = FORMS.keys.find { |name| version.match?(FORMS[name]) }
    raise ArgumentError, 'Expected a stable version of three fields, a prerelease of four (2.3.0.1) or a canary of five (2.3.0.1.4)' unless @channel
    raise ArgumentError, 'Tag must be vVERSION' unless tag == "v#{version}"
    @version = version
    @tag = tag
  end

  # Published as a GitHub prerelease: never Latest, never in Homebrew or the stable app's updates.
  def prerelease?
    channel != 'stable'
  end

  # Every channel releases the same app; canary shows its name as gksdud-CAN.
  def app
    'gksdud'
  end

  def identifier
    'io.gksdud.inputswitch'
  end

  def asset_version
    channel == 'stable' ? version : "#{version}-#{channel}"
  end

  def filename
    "#{app}-#{version}.zip"
  end

  # The disk image to drag the app to Applications, for downloads; the app and Homebrew take the archive.
  def dmg_filename
    "#{app}-#{version}.dmg"
  end

  # The name apps up to 1.7.1 download; prereleases and canary releases are never their updates.
  def self_signed_filename
    "#{app}-#{version}-macos-universal.zip" if SELF_SIGNED_COPY && channel == 'stable'
  end

  def outputs
    { version: version, tag: tag, channel: channel, prerelease: prerelease?,
      asset_version: asset_version, filename: filename, self_signed_filename: self_signed_filename.to_s,
      dmg_filename: dmg_filename }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby scripts/release-metadata.rb VERSION TAG' unless ARGV.length == 2
  begin
    ReleaseMetadata.new(*ARGV).outputs.each { |key, value| puts "#{key}=#{value}" }
  rescue ArgumentError => e
    abort e.message
  end
end
