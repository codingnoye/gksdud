# Shared tag validation and asset naming for the release workflow and verifier.
class ReleaseMetadata
  attr_reader :version, :tag

  def initialize(version, tag = "v#{version}")
    raise ArgumentError, 'Expected numeric release version' unless version.match?(/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/)
    unless ["v#{version}", "pre-v#{version}", "canary-v#{version}"].include?(tag)
      raise ArgumentError, 'Tag must be vVERSION, pre-vVERSION or canary-vVERSION and match the release version'
    end
    @version = version
    @tag = tag
  end

  def channel
    tag.start_with?('pre-v') ? 'pre' : tag.start_with?('canary-v') ? 'canary' : 'stable'
  end

  # Published as a GitHub prerelease: never Latest, never in Homebrew or the stable app's updates.
  def prerelease?
    channel != 'stable'
  end

  # Canary is a separate app, gksdud-dev, that updates only from canary releases.
  def app
    channel == 'canary' ? 'gksdud-dev' : 'gksdud'
  end

  def identifier
    channel == 'canary' ? 'io.gksdud.inputswitch.dev' : 'io.gksdud.inputswitch'
  end

  def asset_version
    channel == 'stable' ? version : "#{version}-#{channel}"
  end

  def filename
    channel == 'canary' ? "#{app}-#{version}-macos-universal.zip" : "gksdud-#{asset_version}-macos-universal.zip"
  end

  def outputs
    { version: version, tag: tag, channel: channel, prerelease: prerelease?,
      asset_version: asset_version, filename: filename }
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
