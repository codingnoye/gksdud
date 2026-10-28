require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require_relative 'release-metadata'
require_relative 'resolve-release'

class ReleaseTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_tag_must_match_numeric_app_version
    %w[main v1.2.1 pre-v1.2.0 canary-v1.2.0 v.1.2.0 1.2.0 v1.2.0-beta.1 ../1.2.0].each do |tag|
      assert_raises(ArgumentError) { ReleaseMetadata.new('1.2.0', tag) }
    end
    # Every tag is vVERSION; stable releases have three fields, prereleases four with the fourth from 1, canary releases five
    # with the fifth from 1.
    assert_equal %w[stable pre canary canary], %w[1.2.0 1.2.0.1 1.2.0.1.3 1.2.1.0.1].map { |version| ReleaseMetadata.new(version).channel }
    [%w[1.2.0.1 pre-v1.2.0.1], %w[1.2.0.1.3 canary-v1.2.0.1.3], %w[1.2.0.0 v1.2.0.0], %w[1.2.0.01 v1.2.0.01], %w[1.2.0.1.0 v1.2.0.1.0],
     %w[1.2.0.1.1.1 v1.2.0.1.1.1]].each do |version, tag|
      assert_raises(ArgumentError) { ReleaseMetadata.new(version, tag) }
    end
    ["1.2.0\n", '1.2', '1.2.0-beta.1', '01.2.0', '1.02.0', '1.2.00'].each do |version|
      assert_raises(ArgumentError) { ReleaseMetadata.new(version) }
    end
  end

  def test_stable_and_prerelease_assets_are_separate
    stable = ReleaseMetadata.new('1.2.0', 'v1.2.0')
    pre = ReleaseMetadata.new('1.2.0.1', 'v1.2.0.1')
    canary = ReleaseMetadata.new('1.2.0.1.3', 'v1.2.0.1.3')
    refute stable.prerelease?
    assert pre.prerelease?
    assert canary.prerelease?
    assert_equal 'gksdud-1.2.0.zip', stable.filename
    # The name an app takes for the version it updates to.
    assert_equal 'gksdud-1.2.0.1.zip', pre.filename
    assert_equal 'gksdud-1.2.0.1.3.zip', canary.filename
    # Every channel carries the disk image for downloads.
    assert_equal %w[gksdud-1.2.0.dmg gksdud-1.2.0.1.dmg gksdud-1.2.0.1.3.dmg], [stable, pre, canary].map(&:dmg_filename)
    # Apps up to 1.7.1 download the old name, which holds the self-signed copy while they move to Developer ID.
    assert ReleaseMetadata::SELF_SIGNED_COPY
    assert_equal 'gksdud-1.2.0-macos-universal.zip', stable.self_signed_filename
    assert_nil canary.self_signed_filename
    assert_nil pre.self_signed_filename
    # The Homebrew note about asking again ends with the copy.
    tap = File.read("#{ROOT}/scripts/update-tap.py")[/^MOVING_TO_DEVELOPER_ID = (True|False)$/, 1]
    assert_equal ReleaseMetadata::SELF_SIGNED_COPY.to_s, tap.downcase
    # One app for every channel.
    assert_equal %w[gksdud gksdud gksdud], [stable, pre, canary].map(&:app)
    assert_equal ['io.gksdud.inputswitch'], [stable, pre, canary].map(&:identifier).uniq
    assert_equal 3, [stable, pre, canary].map(&:asset_version).uniq.length
  end

  def test_prerelease_tags_and_main_trigger_on_push
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    triggers = workflow.fetch('on') { workflow.fetch(true) }
    patterns = triggers.fetch('push').fetch('tags')
    assert patterns.any? { |pattern| File.fnmatch?(pattern, 'v1.2.0.1') }, 'No push trigger for v1.2.0.1'
    refute patterns.any? { |pattern| File.fnmatch?(pattern, 'v1.2.0') }, 'Stable tags must use manual release'
    assert_equal ['main'], triggers.fetch('push').fetch('branches')
    checkout = workflow.fetch('jobs').fetch('release').fetch('steps').first
    assert_equal 0, checkout.fetch('with').fetch('fetch-depth'), 'A canary is numbered from tags and history'
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
    with_release_repository do |selection, command, _|
      # Only a prerelease goes out from its tag; stable releases are manual and canary ones come from main.
      %w[v1.2.0 v1.2.0.0.1 pre-v1.2.0.1 canary-v1.2.0.0.1].each do |tag|
        error = assert_raises(RuntimeError) { selection.resolve(event: 'push', tag: tag, version: '', source: '', summary: '') }
        assert_includes error.message, 'Only a prerelease'
      end
      # A prerelease's version is its tag's, after the source's stable version, which must be out already.
      error = assert_raises(RuntimeError) { selection.resolve(event: 'push', tag: 'v1.2.0.1', version: '', source: '', summary: '') }
      assert_match 'v1.2.0 does not exist', error.message
      command.call('git', 'tag', 'v1.2.0')
      result = selection.resolve(event: 'push', tag: 'v1.2.0.1', version: '', source: '', summary: '')
      assert_equal ['1.2.0.1', 'v1.2.0.1', 'pre', true], result.values_at(:version, :tag, :channel, :prerelease)
      assert_raises(ArgumentError) { selection.resolve(event: 'push', tag: 'v1.2.0.0', version: '', source: '', summary: '') }
      # A manual release is stable.
      %w[1.3.0.1 1.3.0.0.1].each do |version|
        assert_raises(ArgumentError) { selection.resolve(event: 'workflow_dispatch', tag: '', version: version, source: 'main', summary: 'Fix input') }
      end
    end
  end

  def test_a_push_to_main_numbers_its_canary_after_the_latest_prerelease_or_stable_release
    with_release_repository do |selection, git, dir|
      push = { event: 'push', tag: 'main', version: '', source: '', summary: '', branch: true }
      commit = ->(subject) { git.call('git', 'commit', '--allow-empty', '-m', subject) }
      commit.call('Second')
      error = assert_raises(RuntimeError) { selection.resolve(**push) }
      assert_includes error.message, 'No prerelease or stable release tag'
      git.call('git', 'tag', 'v1.2.0', 'HEAD~1')
      git.call('git', 'tag', 'v1.1.9', 'HEAD~1')
      git.call('git', 'tag', 'pre-v1.5.0.1')
      commit.call('Change')
      result = selection.resolve(**push)
      assert_equal ['1.2.0.0.2', 'v1.2.0.0.2', 'canary', true], result.values_at(:version, :tag, :channel, :prerelease)
      assert_equal git.call('git', 'rev-parse', 'HEAD'), result.fetch(:source_sha)
      assert_equal 'gksdud-1.2.0.0.2.zip', result.fetch(:filename)
      # A prerelease, or a stable release, of the same commit leaves the number of a rerun alone.
      git.call('git', 'tag', '-a', '-m', 'Prerelease', 'v1.2.0.1')
      assert_equal '1.2.0.0.2', selection.resolve(**push).fetch(:version)
      commit.call('After the prerelease')
      assert_equal '1.2.0.1.1', selection.resolve(**push).fetch(:version)
      # A prerelease off this branch is not before the commit.
      git.call('git', 'tag', 'v1.2.0.9', git.call('git', 'commit-tree', '-m', 'Elsewhere', 'HEAD^{tree}'))
      git.call('git', 'tag', 'v1.2.0.1.1', 'HEAD')
      commit.call('Next')
      assert_equal '1.2.0.1.2', selection.resolve(**push).fetch(:version)
      git.call('git', 'tag', 'v1.2.1', 'HEAD~1')
      assert_equal '1.2.1.0.1', selection.resolve(**push).fetch(:version)
      # A prerelease pushed before its stable release is refused and does not count.
      git.call('git', 'tag', 'v1.3.0.1', 'HEAD~1')
      assert_equal '1.2.1.0.1', selection.resolve(**push).fetch(:version)
      git.call('git', 'tag', 'v1.3.0', 'HEAD~1')
      assert_equal '1.3.0.1.1', selection.resolve(**push).fetch(:version)
      # A local build numbers itself the same way.
      FileUtils.cp("#{ROOT}/build.sh", "#{dir}/build.sh")
      script = File.read("#{ROOT}/build.sh")[/^if \[\[ \$channel != stable.*?^fi$/m]
      output, = Open3.capture2e({ 'channel' => 'dev' }, '/bin/bash', '-c', "set -euo pipefail\n#{script}\necho \"$GKSDUD_APP_VERSION\"", chdir: dir)
      assert_equal '1.3.0.1.1', output.strip
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
  def release_arguments(tag, tag_type: 'commit', message: '', root: ROOT)
    metadata = ReleaseMetadata.new(tag.sub(/\A(pre-|canary-)?v/, ''), tag)
    head, = Open3.capture2('git', 'rev-parse', 'HEAD', chdir: root)
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    step = workflow.fetch('jobs').fetch('release').fetch('steps').find do |item|
      item.fetch('name', '').start_with?('Create stable draft')
    end
    Dir.mktmpdir('gksdud-release-test-') do |dir|
      File.write("#{dir}/gh", <<~RUBY)
        #!/usr/bin/ruby
        require 'json'
        if ARGV.first == 'api'
          puts ARGV[1].include?('/git/ref/tags/') ? "\#{ENV.fetch('TAG_TYPE')} 0123abc" : ENV.fetch('TAG_MESSAGE')
          exit
        end
        File.write(ENV.fetch('CAPTURE'), JSON.generate(ARGV))
        File.write(ENV.fetch('NOTES'), File.read(ARGV.fetch(ARGV.index('--notes-file') + 1)))
      RUBY
      File.chmod(0755, "#{dir}/gh")
      env = metadata.outputs.transform_keys { |key| key.to_s.upcase }.transform_values(&:to_s)
      env.merge!('PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'GITHUB_REPOSITORY' => 'codingnoye/gksdud',
                 'SOURCE_ROOT' => 'release-source', 'SOURCE_SHA' => head.strip, 'RUNNER_TEMP' => dir, 'TAG_TYPE' => tag_type, 'TAG_MESSAGE' => message,
                 'CAPTURE' => "#{dir}/args.json", 'NOTES' => "#{dir}/notes.md")
      output, status = Open3.capture2e(env, '/bin/bash', '-c', step.fetch('run'), chdir: root)
      assert status.success?, output
      [JSON.parse(File.read("#{dir}/args.json")), File.read("#{dir}/notes.md")]
    end
  end

  def test_stable_remains_a_draft
    args, = release_arguments('v1.2.0')
    assert_equal ['release', 'create', 'v1.2.0'], args.first(3)
    assert_includes args, '--draft'
    refute_includes args, '--prerelease'
    assert_equal ['release-source/outputs/gksdud-1.2.0.zip', 'release-source/outputs/gksdud-1.2.0-macos-universal.zip',
                  'release-source/outputs/gksdud-1.2.0.dmg', 'release-source/outputs/release-1.2.0/SHA256SUMS'], args[3, 4]
    assert_includes args, '.github/RELEASE_NOTES.md'
    assert_includes args, '--verify-tag'
  end

  def test_prerelease_is_published_with_the_tag_message_without_changing_latest
    message = "### 요약\n- 프리릴리즈 항목"
    args, notes = release_arguments('v1.2.0.1', tag_type: 'tag', message: message)
    assert_equal ['release', 'create', 'v1.2.0.1'], args.first(3)
    assert_includes args, '--prerelease'
    assert_includes args, '--latest=false'
    refute_includes args, '--draft'
    assert_includes args, 'gksdud 1.2.0.1 Pre-release'
    assert_equal ['release-source/outputs/gksdud-1.2.0.1.zip', 'release-source/outputs/gksdud-1.2.0.1.dmg',
                  'release-source/outputs/release-1.2.0.1-pre/SHA256SUMS'], args[3, 3]
    assert_includes args, '--generate-notes'
    assert_includes args, '--verify-tag'
    assert notes.start_with?("#{message}\n\n### 테스트용"), notes
    _, notes = release_arguments('v1.2.0.1')
    assert_equal File.read("#{ROOT}/.github/PRERELEASE_NOTES.md"), notes, 'A lightweight tag has no message'
  end

  def test_canary_is_published_with_its_commits_without_changing_latest
    with_release_repository do |_, git, dir|
      FileUtils.mkdir_p("#{dir}/.github")
      FileUtils.cp("#{ROOT}/.github/CANARY_NOTES.md", "#{dir}/.github/")
      commit = lambda do |subject|
        git.call('git', 'commit', '--allow-empty', '-m', "#{subject}\n\nBody that stays out")
        [git.call('git', 'rev-parse', '--short', 'HEAD'), git.call('git', 'rev-parse', 'HEAD')]
      end
      git.call('git', 'tag', 'v1.2.0')
      commit.call('[FIX] Published before')
      git.call('git', 'tag', 'v1.2.0.0.1')
      first = commit.call('[FEAT] Channel (#81)')
      second = commit.call('Typo')
      args, notes = release_arguments('v1.2.0.0.3', root: dir)
      assert_equal ['release', 'create', 'v1.2.0.0.3'], args.first(3)
      assert_includes args, '--prerelease'
      assert_includes args, '--latest=false'
      refute_includes args, '--draft'
      refute_includes args, '--generate-notes'
      assert_includes args, 'gksdud 1.2.0.0.3 Canary'
      assert_equal ['release-source/outputs/gksdud-1.2.0.0.3.zip', 'release-source/outputs/gksdud-1.2.0.0.3.dmg',
                    'release-source/outputs/release-1.2.0.0.3-canary/SHA256SUMS'], args[3, 3]
      # Since the previous canary, newest first, each its hash linked to the commit and its title alone.
      expected = [second, first].zip(['Typo', '[FEAT] Channel (#81)']).map do |(short, full), title|
        "- [#{short}](https://github.com/codingnoye/gksdud/commit/#{full}) #{title}\n"
      end
      assert_equal "### 요약\n#{expected.join}\n#{File.read("#{ROOT}/.github/CANARY_NOTES.md")}", notes
      # Past twenty, the rest is counted; with no canary before, from the stable release.
      git.call('git', 'tag', '-d', 'v1.2.0.0.1')
      22.times { |index| git.call('git', 'commit', '--allow-empty', '-m', "Commit #{index}") }
      _, notes = release_arguments('v1.2.0.0.25', root: dir)
      items = notes.split("\n\n").first.lines.drop(1)
      assert_equal 21, items.length
      assert_equal "- 외 커밋 5개", items.last.chomp
    end
  end

  def workflow_steps
    YAML.load_file("#{ROOT}/.github/workflows/release.yml").fetch('jobs').fetch('release').fetch('steps')
  end

  def test_canary_runs_apart_tests_the_scripts_and_skips_documents
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    assert_includes workflow.fetch('concurrency').fetch('group'), "github.event_name == 'push' && github.ref_type == 'branch' && 'canary' || 'manual'"
    triggers = workflow.fetch('on') { workflow.fetch(true) }
    ignored = triggers.fetch('push').fetch('paths-ignore')
    assert(%w[README.md docs/cli.md tests/README.md].all? { |path| ignored.any? { |glob| File.fnmatch?(glob.sub('**.', '**/*.'), path, File::FNM_PATHNAME) || File.fnmatch?(glob, path) } })
    refute(%w[main.swift build.sh .github/workflows/release.yml].any? { |path| ignored.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) } })
    steps = workflow_steps
    tests = steps.index { |step| step['name'] == 'Test release scripts' }
    assert tests && tests < steps.index { |step| step['name'] == 'Create tag for the verified source' }
    build = steps.find { |step| step['name'].to_s.start_with?('Build') }
    assert_equal "${{ steps.version.outputs.channel == 'canary' && 'canary' || 'stable' }}", build.fetch('env').fetch('GKSDUD_CHANNEL'), 'A release never ships a local build'
  end

  # The pruning and tag cleanup steps against a fake gh; nothing reaches GitHub.
  def run_step(name, env, gh)
    step = workflow_steps.find { |item| item['name'] == name }
    Dir.mktmpdir('gksdud-step-test-') do |dir|
      File.write("#{dir}/gh", "#!/bin/bash\necho \"$*\" >> #{dir}/calls\n#{gh}\n")
      File.chmod(0755, "#{dir}/gh")
      output, status = Open3.capture2e(env.merge('PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'GITHUB_REPOSITORY' => 'codingnoye/gksdud'), '/bin/bash', '-c', step.fetch('run'))
      assert status.success?, output
      [step, File.exist?("#{dir}/calls") ? File.read("#{dir}/calls").lines.map(&:strip) : []]
    end
  end

  def test_only_the_latest_twenty_canaries_are_kept
    tags = (1..23).map { |n| "v1.2.0.1.#{24 - n}" }.each_slice(5).flat_map { |slice| slice + ['v1.2.0', 'v1.2.0.1'] } + ['canary-v2.0.3', 'canary-v2.0.2.1.1']
    step, calls = run_step('Keep the latest canary releases', {}, %(if [[ $1 == release && $2 == list ]]; then printf '%s\\n' #{tags.join(' ')}; fi))
    assert_equal "steps.version.outputs.channel == 'canary'", step.fetch('if')
    deleted = calls.select { |call| call.start_with?('release delete') }.map { |call| call.split[2] }
    assert_equal %w[v1.2.0.1.3 v1.2.0.1.2 v1.2.0.1.1], deleted
  end

  def test_a_failed_canary_leaves_no_tag_without_a_release
    name = 'Remove the tag of a canary that was not published'
    lookup = 'api repos/codingnoye/gksdud/releases/tags/v1.2.0.1.3'
    step, calls = run_step(name, { 'TAG' => 'v1.2.0.1.3' }, %(if [[ $2 == */releases/tags/* ]]; then echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi))
    assert_equal "(failure() || cancelled()) && steps.version.outputs.channel == 'canary' && steps.version.outputs.tag_exists == 'false'", step.fetch('if')
    assert_equal [lookup, 'api --method DELETE repos/codingnoye/gksdud/git/refs/tags/v1.2.0.1.3'], calls
    _, calls = run_step(name, { 'TAG' => 'v1.2.0.1.3' }, 'true')
    assert_equal [lookup], calls, 'A published canary keeps its tag'
    _, calls = run_step(name, { 'TAG' => 'v1.2.0.1.3' }, %(echo 'error connecting to api.github.com' >&2; exit 1))
    assert_equal [lookup], calls, 'Not when asking failed'
  end

  def test_stable_publication_requires_explicit_dispatch_and_keeps_tap_in_actions
    workflow = YAML.load_file("#{ROOT}/.github/workflows/release.yml")
    triggers = workflow.fetch('on') { workflow.fetch(true) }
    inputs = triggers.fetch('workflow_dispatch').fetch('inputs')
    assert_equal %w[make_latest release_summary release_warning source_ref version], inputs.keys.sort
    assert_equal true, inputs.fetch('make_latest').fetch('default')
    refute inputs.fetch('release_warning').fetch('required')
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

  def publication_result(draft: true, prerelease: false, actual_tag: 'v1.2.0', summary: 'Input fixes', warning: '', latest: 'true', view_exit: 0, edit_exit: 0)
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
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'RELEASE_SUMMARY' => summary, 'RELEASE_WARNING' => warning, 'MAKE_LATEST' => latest,
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
    refute_includes notes, '### 경고'
  end

  def test_publish_can_leave_the_latest_release_alone
    status, args, _, output = publication_result(latest: 'false')
    assert status.success?, output
    assert_equal ['--draft=false', '--latest=false'], args.last(2)
  end

  def test_publish_adds_the_warning_section_after_the_summary
    status, _, notes, output = publication_result(summary: '- 서명 변경', warning: " - 손쉬운 사용 권한을 다시 허용\n")
    assert status.success?, output
    assert_includes notes, "### 요약\n\n- 서명 변경\n\n### 경고\n\n- 손쉬운 사용 권한을 다시 허용\n\n### 설치"
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
