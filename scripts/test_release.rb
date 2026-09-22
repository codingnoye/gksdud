require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require_relative 'release-metadata'
require_relative 'resolve-release'

class ReleaseTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_tag_must_match_numeric_app_version
    %w[main v1.2.1 pre-v.1.2.1 pre-v1.2.1 pre-v1.2.0-beta.1 pre-v.1.2.0-beta.1 ../1.2.0].each do |tag|
      assert_raises(ArgumentError) { ReleaseMetadata.new('1.2.0', tag) }
    end
    ["1.2.0\n", '1.2', '1.2.0-beta.1', '01.2.0', '1.02.0', '1.2.00'].each do |version|
      assert_raises(ArgumentError) { ReleaseMetadata.new(version) }
    end
  end

  def test_stable_and_prerelease_assets_are_separate
    stable = ReleaseMetadata.new('1.2.0', 'v1.2.0')
    pre = ReleaseMetadata.new('1.2.0', 'pre-v1.2.0')
    refute stable.prerelease?
    assert pre.prerelease?
    assert_equal 'gksdud-1.2.0-macos-universal.zip', stable.filename
    assert_equal 'gksdud-1.2.0-pre-macos-universal.zip', pre.filename
    refute_equal stable.asset_version, pre.asset_version
    legacy = ReleaseMetadata.new('1.2.0', 'pre-v.1.2.0')
    assert legacy.prerelease?
    assert_equal pre.filename, legacy.filename
  end

  def test_workflow_triggers_for_both_prerelease_tag_formats
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    triggers = workflow.fetch('on') { workflow.fetch(true) }
    patterns = triggers.fetch('push').fetch('tags')
    %w[v1.2.0 pre-v1.2.0 pre-v.1.2.0].each do |tag|
      assert patterns.any? { |pattern| File.fnmatch?(pattern, tag) }, "No push trigger for #{tag}"
    end
  end

  def with_release_repository
    Dir.mktmpdir('gksdud-source-test-') do |dir|
      command = lambda do |*args|
        output, status = Open3.capture2e(*args, chdir: dir)
        assert status.success?, output
        output.strip
      end
      command.call('git', 'init', '-b', 'main')
      command.call('git', 'config', 'user.name', 'Release Test')
      command.call('git', 'config', 'user.email', 'test@example.invalid')
      File.write("#{dir}/Info.plist", '<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.2.0</string></dict></plist>')
      command.call('git', 'add', 'Info.plist')
      command.call('git', 'commit', '-m', 'Initial source')
      command.call('git', 'remote', 'add', 'origin', dir)
      yield ReleaseSelection.new(dir), command, dir
    end
  end

  def test_pushed_tags_must_match_source_version
    with_release_repository do |selection, _, _|
      %w[v1.2.0 pre-v1.2.0 pre-v.1.2.0].each do |tag|
        result = selection.resolve(event: 'push', tag: tag, version: '', source: '', summary: '')
        assert_equal '1.2.0', result.fetch(:version)
        assert_equal tag.start_with?('pre-v'), result.fetch(:prerelease)
      end
      assert_raises(ArgumentError) { selection.resolve(event: 'push', tag: 'v9.0.0', version: '', source: '', summary: '') }
    end
  end

  def test_manual_release_pins_branch_or_commit_and_does_not_create_tags
    with_release_repository do |selection, git, dir|
      sha = git.call('git', 'rev-parse', 'HEAD')
      %W[main #{sha}].each do |source|
        result = selection.resolve(event: 'workflow_dispatch', tag: '', version: '1.3.0', source: source, summary: 'Fix input')
        assert_equal sha, result.fetch(:source_sha)
        assert_equal 'v1.3.0', result.fetch(:tag)
        assert_equal false, result.fetch(:tag_exists)
      end
      assert_empty git.call('git', 'tag', '--list')
      assert_includes File.read("#{dir}/Info.plist"), '<string>1.2.0</string>'
      File.write("#{dir}/next", 'next source')
      git.call('git', 'add', 'next')
      git.call('git', 'commit', '-m', 'Move branch')
      result = selection.resolve(event: 'workflow_dispatch', tag: '', version: '1.3.0', source: sha, summary: 'Pinned release')
      assert_equal sha, result.fetch(:source_sha)
    end
  end

  def test_existing_lightweight_and_annotated_tags_are_never_retargeted
    with_release_repository do |selection, git, dir|
      %w[lightweight annotated].each_with_index do |kind, index|
        version = "1.3.#{index}"
        args = ['git', 'tag']
        args += ['-a', '-m', 'Release'] if kind == 'annotated'
        git.call(*args, "v#{version}")
        result = selection.resolve(event: 'workflow_dispatch', tag: '', version: version, source: 'main', summary: 'Fix input')
        assert_equal true, result.fetch(:tag_exists)
      end
      File.write("#{dir}/next", 'different source')
      git.call('git', 'add', 'next')
      git.call('git', 'commit', '-m', 'Change source')
      %w[1.3.0 1.3.1].each do |version|
        error = assert_raises(RuntimeError) { selection.resolve(event: 'workflow_dispatch', tag: '', version: version, source: 'main', summary: 'Fix input') }
        assert_includes error.message, 'different commit'
      end
    end
  end

  def test_manual_release_rejects_missing_summary_bad_version_or_source
    with_release_repository do |selection, _, _|
      base = { event: 'workflow_dispatch', tag: '', version: '1.3.0', source: 'main', summary: 'Fix input' }
      [{ summary: '' }, { version: '1.03.0' }, { source: '--upload-pack=nope' }, { source: 'missing' }].each do |change|
        assert_raises(StandardError) { selection.resolve(**base.merge(change)) }
      end
    end
  end

  def test_requested_version_is_applied_only_to_selected_checkout
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    step = workflow.fetch('jobs').fetch('release').fetch('steps').find { |item| item['name'] == 'Prepare selected source version' }
    Dir.mktmpdir('gksdud-selected-version-') do |dir|
      Dir.mkdir("#{dir}/release-source")
      original = File.read("#{ROOT}/Info.plist")
      File.write("#{dir}/Info.plist", original)
      File.write("#{dir}/release-source/Info.plist", original)
      File.write("#{dir}/release-source/LICENSE", 'Test license')
      File.write("#{dir}/release-source/build.sh", 'true')
      output, status = Open3.capture2e({ 'RELEASE_VERSION' => '9.8.7' }, '/bin/bash', '-c', step.fetch('run'), chdir: dir)
      assert status.success?, output
      version, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', "#{dir}/release-source/Info.plist")
      assert status.success?, version
      assert_equal '9.8.7', version.strip
      assert_equal original, File.read("#{dir}/Info.plist")
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
                 'SOURCE_ROOT' => 'release-source',
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
    assert_includes args, 'release-source/outputs/gksdud-1.2.0-macos-universal.zip'
    assert_includes args, 'release-source/outputs/release-1.2.0/SHA256SUMS'
    assert_includes args, '.github/RELEASE_NOTES.md'
    assert_includes args, '--verify-tag'
  end

  def test_prerelease_is_published_without_changing_latest
    %w[pre-v1.2.0 pre-v.1.2.0].each do |tag|
      args = release_arguments(tag)
      assert_equal ['release', 'create', tag], args.first(3)
      assert_includes args, '--prerelease'
      assert_includes args, '--latest=false'
      refute_includes args, '--draft'
      assert_includes args, 'release-source/outputs/gksdud-1.2.0-pre-macos-universal.zip'
      assert_includes args, 'release-source/outputs/release-1.2.0-pre/SHA256SUMS'
      assert_includes args, '.github/PRERELEASE_NOTES.md'
      assert_includes args, '--generate-notes'
      assert_includes args, '--verify-tag'
    end
  end

  def test_stable_publication_requires_explicit_dispatch_and_keeps_tap_in_actions
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    triggers = workflow.fetch('on') { workflow.fetch(true) }
    inputs = triggers.fetch('workflow_dispatch').fetch('inputs')
    assert_equal %w[release_summary source_ref version], inputs.keys.sort
    assert_equal 'main', inputs.fetch('source_ref').fetch('default')
    steps = workflow.fetch('jobs').fetch('release').fetch('steps')
    publish = steps.find { |step| step['name'] == 'Publish verified stable draft' }
    tap = steps.find { |step| step['name'] == 'Verify published assets and open Homebrew update PR' }
    assert_equal "github.event_name == 'workflow_dispatch' && steps.version.outputs.prerelease == 'false'", publish.fetch('if')
    assert_equal publish.fetch('if'), tap.fetch('if')
    assert_operator steps.index(publish), :>, steps.index(steps.find { |step| step['id'] == 'existing' })
    assert_operator steps.index(tap), :>, steps.index(publish)
    assert_includes tap.fetch('run'), 'python3 scripts/update-tap.py "$RELEASE_TAG"'
    create_tag = steps.find { |step| step['name'] == 'Create tag for the verified source' }
    verify_archive = steps.find { |step| step['name'] == 'Verify archive and prepare release metadata' }
    assert_operator steps.index(create_tag), :>, steps.index(verify_archive)
    assert_equal 'false', create_tag.fetch('if')[/== '([^']+)'/, 1]
  end

  def publication_result(draft: true, prerelease: false, actual_tag: 'v1.2.0', summary: 'Input fixes', view_exit: 0, edit_exit: 0)
    Dir.mktmpdir('gksdud-publish-test-') do |dir|
      File.write("#{dir}/gh", <<~RUBY)
        #!/usr/bin/ruby
        require 'json'
        if ARGV.first(2) == ['release', 'view']
          puts ENV.fetch('RELEASE_JSON')
          exit ENV.fetch('VIEW_EXIT').to_i
        end
        File.write(ENV.fetch('CAPTURE'), JSON.generate(ARGV))
        File.write(ENV.fetch('NOTES'), File.read(ARGV.fetch(ARGV.index('--notes-file') + 1)))
        exit ENV.fetch('EDIT_EXIT').to_i
      RUBY
      File.chmod(0755, "#{dir}/gh")
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'RELEASE_SUMMARY' => summary,
              'RELEASE_JSON' => JSON.generate(tagName: actual_tag, isDraft: draft, isPrerelease: prerelease),
              'CAPTURE' => "#{dir}/args.json", 'NOTES' => "#{dir}/notes.md",
              'VIEW_EXIT' => view_exit.to_s, 'EDIT_EXIT' => edit_exit.to_s }
      output, status = Open3.capture2e(env, '/usr/bin/ruby', "#{ROOT}/scripts/publish-release.rb", 'codingnoye/gksdud', 'v1.2.0')
      args = File.exist?("#{dir}/args.json") ? JSON.parse(File.read("#{dir}/args.json")) : nil
      notes = File.exist?("#{dir}/notes.md") ? File.read("#{dir}/notes.md") : nil
      [status, args, notes, output]
    end
  end

  def test_publish_uses_literal_summary_and_never_uploads_assets
    summary = "- Option+` fix\n- Literal $(touch nope) \\1 text"
    status, args, notes, output = publication_result(summary: summary)
    assert status.success?, output
    assert_equal ['release', 'edit', 'v1.2.0', '--repo', 'codingnoye/gksdud', '--notes-file'], args.first(6)
    assert_equal ['--draft=false', '--latest'], args.last(2)
    assert_equal 9, args.length
    assert_includes notes, summary
    refute_includes notes, '<!-- 게시 전'
    assert_includes notes, 'brew install --cask codingnoye/tap/gksdud'
  end

  def test_published_release_is_not_edited_on_retry
    status, args, notes, output = publication_result(draft: false)
    assert status.success?, output
    assert_nil args
    assert_nil notes
  end

  def test_publication_rejects_invalid_release_missing_summary_and_failed_lookup
    [{ prerelease: true }, { actual_tag: 'v1.2.1' }, { summary: " \n" }, { view_exit: 1 }].each do |options|
      status, args, notes, = publication_result(**options)
      refute status.success?, options.inspect
      assert_nil args
      assert_nil notes
    end
    status, = publication_result(edit_exit: 1)
    refute status.success?
  end
end
