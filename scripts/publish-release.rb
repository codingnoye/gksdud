require 'json'
require 'open3'
require 'tempfile'

repo, tag = ARGV
abort 'Usage: publish-release.rb OWNER/REPO vVERSION' unless ARGV.length == 2 &&
  repo.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/) &&
  tag.match?(/\Av\d+\.\d+\.\d+\z/)
summary = ENV.fetch('RELEASE_SUMMARY', '').strip
abort 'Release summary is required' if summary.empty?

output, status = Open3.capture2e('gh', 'release', 'view', tag, '--repo', repo,
                              '--json', 'tagName,isDraft,isPrerelease')
abort output unless status.success?
release = JSON.parse(output)
abort 'Expected the requested stable release' unless release.fetch('tagName') == tag &&
  release.fetch('isPrerelease') == false
unless release.fetch('isDraft')
  puts 'Stable release is already published. No release metadata or assets changed.'
  exit
end

notes = File.read(File.expand_path('../.github/RELEASE_NOTES.md', __dir__))
marker = '<!-- 게시 전 이 버전의 사용자용 변경 요약을 짧게 작성하세요. 앱이 이 구역을 표시합니다. -->'
abort 'Expected one release summary placeholder' unless notes.scan(marker).length == 1
Tempfile.create(['gksdud-release-notes-', '.md']) do |file|
  file.write(notes.sub(marker) { summary })
  file.flush
  success = system('gh', 'release', 'edit', tag, '--repo', repo,
                   '--notes-file', file.path, '--draft=false', '--latest')
  abort 'Could not publish the verified draft' unless success
end
