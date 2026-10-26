require 'open3'
require_relative 'release-metadata'

class ReleaseSelection
  def initialize(root)
    @root = root
  end

  def capture(*args)
    output, status = Open3.capture2e(*args, chdir: @root)
    raise output unless status.success?
    output.strip
  end

  # A canary goes out on every push to main, numbered by the commits since the highest prerelease or stable release before
  # its commit, in a fifth field: v2.3.0.1.4 follows v2.3.0.1, v2.3.1.0.2 follows v2.3.1. A release later made from the same
  # commit leaves the number alone, so a rerun gives the same one.
  def canary_version
    tags = capture('git', 'tag', '--list', 'v*', '--merged', 'HEAD^').lines.map(&:strip)
    known = capture('git', 'tag', '--list', 'v*').lines.map(&:strip)
    releases = tags.map do |name|
      fields = name[/\Av(\d+\.\d+\.\d+(?:\.[1-9]\d*)?)\z/, 1]
      # A prerelease tag counts only with its stable release, as one pushed before it is refused.
      next unless fields && (fields.count('.') == 2 || known.include?("v#{fields.split('.').first(3).join('.')}"))
      [(fields.split('.').map(&:to_i) + [0]).first(4), name]
    end.compact
    raise 'No prerelease or stable release tag to number the canary after' if releases.empty?
    base, tag = releases.max_by(&:first)
    "#{base.join('.')}.#{capture('git', 'rev-list', '--count', "#{tag}..HEAD")}"
  end

  def resolve(event:, tag:, version:, source:, summary:, branch: false)
    if event == 'push' && branch
      version = canary_version
      metadata = ReleaseMetadata.new(version)
      sha = capture('git', 'rev-parse', 'HEAD^{commit}')
    elsif event == 'workflow_dispatch'
      raise 'Release summary is required' if summary.strip.empty?
      raise 'Expected a branch or commit' if source.empty? || source.start_with?('-') || source.match?(/[\r\n]/)
      metadata = ReleaseMetadata.new(version)
      raise ArgumentError, 'A manual release is stable, of three fields' unless metadata.channel == 'stable'
      capture('git', 'fetch', '--no-tags', '--', 'origin', source)
      sha = capture('git', 'rev-parse', 'FETCH_HEAD^{commit}')
    else
      raise 'Expected a tag push or manual release' unless event == 'push'
      # Only a prerelease goes out from its tag, which names its version; stable releases are manual, canary ones from main.
      raise 'Only a prerelease, vX.Y.Z.P, is released from a pushed tag' unless tag.match?(/\Av\d+\.\d+\.\d+\.\d+\z/)
      version = tag.delete_prefix('v')
      metadata = ReleaseMetadata.new(version, tag)
      sha = capture('git', 'rev-parse', 'HEAD^{commit}')
      # Numbered on a stable release not out yet, it would outrank that release and never be updated to it.
      if metadata.channel == 'pre'
        base = "refs/tags/v#{version.split('.').first(3).join('.')}"
        raise "A prerelease follows a published stable release; #{base.delete_prefix('refs/tags/')} does not exist" if capture('git', 'ls-remote', '--tags', 'origin', base).empty?
      end
    end
    ref = "refs/tags/#{metadata.tag}"
    refs = capture('git', 'ls-remote', '--tags', 'origin', ref, "#{ref}^{}").lines.map do |line|
      object, name = line.split
      [name, object]
    end.to_h
    existing = refs["#{ref}^{}"] || refs[ref]
    raise 'Release tag already points to a different commit' if existing && existing != sha
    metadata.outputs.merge(source_sha: sha, tag_exists: !existing.nil?)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    result = ReleaseSelection.new(Dir.pwd).resolve(
      event: ENV.fetch('GITHUB_EVENT_NAME'), tag: ENV.fetch('GITHUB_REF_NAME', ''),
      version: ENV.fetch('REQUESTED_VERSION', ''), source: ENV.fetch('SOURCE_REF', ''),
      summary: ENV.fetch('RELEASE_SUMMARY', ''), branch: ENV.fetch('GITHUB_REF_TYPE', '') == 'branch')
    result.each { |key, value| puts "#{key}=#{value}" }
  rescue StandardError => e
    abort e.message
  end
end
