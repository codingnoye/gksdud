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

  def resolve(event:, tag:, version:, source:, summary:)
    if event == 'workflow_dispatch'
      raise 'Release summary is required' if summary.strip.empty?
      raise 'Expected a branch or commit' if source.empty? || source.start_with?('-') || source.match?(/[\r\n]/)
      metadata = ReleaseMetadata.new(version)
      capture('git', 'fetch', '--no-tags', '--', 'origin', source)
      sha = capture('git', 'rev-parse', 'FETCH_HEAD^{commit}')
    else
      raise 'Expected a tag push or manual release' unless event == 'push'
      version = capture('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', 'Info.plist')
      metadata = ReleaseMetadata.new(version, tag)
      sha = capture('git', 'rev-parse', 'HEAD^{commit}')
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
      summary: ENV.fetch('RELEASE_SUMMARY', ''))
    result.each { |key, value| puts "#{key}=#{value}" }
  rescue StandardError => e
    abort e.message
  end
end
