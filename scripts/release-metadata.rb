# Shared tag validation and asset naming for the release workflow and verifier.
class ReleaseMetadata
  attr_reader :version, :tag

  def initialize(version, tag = "v#{version}")
    raise ArgumentError, 'Expected numeric release version' unless version.match?(/\A\d+\.\d+\.\d+\z/)
    unless ["v#{version}", "pre-v.#{version}"].include?(tag)
      raise ArgumentError, 'Tag must be vVERSION or pre-v.VERSION and match Info.plist'
    end
    @version = version
    @tag = tag
  end

  def prerelease?
    tag.start_with?('pre-v.')
  end

  def asset_version
    prerelease? ? "#{version}-pre" : version
  end

  def filename
    "gksdud-#{asset_version}-macos-universal.zip"
  end

  def outputs
    { version: version, tag: tag, prerelease: prerelease?,
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
