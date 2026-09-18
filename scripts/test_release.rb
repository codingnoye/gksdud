require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require_relative 'release-metadata'

class ReleaseTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_tag_must_match_numeric_app_version
    %w[main v1.2.1 pre-v.1.2.1 pre-v1.2.0 pre-v.1.2.0-beta.1 ../1.2.0].each do |tag|
      assert_raises(ArgumentError) { ReleaseMetadata.new('1.2.0', tag) }
    end
    ["1.2.0\n", '1.2', '1.2.0-beta.1'].each do |version|
      assert_raises(ArgumentError) { ReleaseMetadata.new(version) }
    end
  end

  def test_stable_and_prerelease_assets_are_separate
    stable = ReleaseMetadata.new('1.2.0', 'v1.2.0')
    pre = ReleaseMetadata.new('1.2.0', 'pre-v.1.2.0')
    refute stable.prerelease?
    assert pre.prerelease?
    assert_equal 'gksdud-1.2.0-macos-universal.zip', stable.filename
    assert_equal 'gksdud-1.2.0-pre-macos-universal.zip', pre.filename
    refute_equal stable.asset_version, pre.asset_version
  end

  def test_workflow_validates_pushed_tags_before_building
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    step = workflow.fetch('jobs').fetch('release').fetch('steps').find { |item| item['id'] == 'version' }
    version, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', "#{ROOT}/Info.plist")
    assert status.success?, version
    version = version.strip
    Dir.mktmpdir('gksdud-tag-test-') do |dir|
      ["v#{version}", "pre-v.#{version}", 'pre-v.999.0.0'].each do |tag|
        output_path = "#{dir}/#{tag}"
        env = { 'GITHUB_EVENT_NAME' => 'push', 'GITHUB_REF_NAME' => tag, 'GITHUB_OUTPUT' => output_path }
        output, result = Open3.capture2e(env, '/bin/bash', '-c', step.fetch('run'), chdir: ROOT)
        if tag == 'pre-v.999.0.0'
          refute result.success?, 'Mismatched tag unexpectedly accepted'
          assert_empty File.read(output_path)
        else
          assert result.success?, output
          actual = File.readlines(output_path).map { |line| line.strip.split('=', 2) }.to_h
          assert_equal version, actual.fetch('version')
          assert_equal tag, actual.fetch('tag')
          assert_equal tag.start_with?('pre-v.').to_s, actual.fetch('prerelease')
        end
      end
    end
  end

  # Run the actual publication shell block against a fake gh command. No network
  # or signing secrets are used, and no tag or release is created.
  def release_arguments(tag)
    metadata = ReleaseMetadata.new('1.2.0', tag)
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    step = workflow.fetch('jobs').fetch('release').fetch('steps').find do |item|
      item.fetch('name', '').start_with?('Create stable draft')
    end
    Dir.mktmpdir('gksdud-release-test-') do |dir|
      File.write("#{dir}/gh", "#!/usr/bin/ruby\nrequire 'json'\nFile.write(ENV.fetch('CAPTURE'), JSON.generate(ARGV))\n")
      File.chmod(0755, "#{dir}/gh")
      env = metadata.outputs.transform_keys { |key| key.to_s.upcase }.transform_values(&:to_s)
      env.merge!('PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'GITHUB_REPOSITORY' => 'codingnoye/gksdud',
                 'CAPTURE' => "#{dir}/args.json")
      output, status = Open3.capture2e(env, '/bin/bash', '-c', step.fetch('run'), chdir: ROOT)
      assert status.success?, output
      JSON.parse(File.read("#{dir}/args.json"))
    end
  end

  def test_stable_remains_a_draft
    args = release_arguments('v1.2.0')
    assert_equal ['release', 'create', 'v1.2.0'], args.first(3)
    assert_includes args, '--draft'
    refute_includes args, '--prerelease'
    assert_includes args, 'outputs/gksdud-1.2.0-macos-universal.zip'
    assert_includes args, 'outputs/release-1.2.0/SHA256SUMS'
    assert_includes args, '.github/RELEASE_NOTES.md'
    assert_includes args, '--verify-tag'
  end

  def test_prerelease_is_published_without_changing_latest
    args = release_arguments('pre-v.1.2.0')
    assert_equal ['release', 'create', 'pre-v.1.2.0'], args.first(3)
    assert_includes args, '--prerelease'
    assert_includes args, '--latest=false'
    refute_includes args, '--draft'
    assert_includes args, 'outputs/gksdud-1.2.0-pre-macos-universal.zip'
    assert_includes args, 'outputs/release-1.2.0-pre/SHA256SUMS'
    assert_includes args, '.github/PRERELEASE_NOTES.md'
    assert_includes args, '--generate-notes'
    assert_includes args, '--verify-tag'
  end
end
