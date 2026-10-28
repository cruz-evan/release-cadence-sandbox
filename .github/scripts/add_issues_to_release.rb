#!/usr/bin/env ruby

require_relative "pull_issues_from_gh"

repo_slug = ENV["GITHUB_REPOSITORY"]
token = ReleaseNotesIssueLinks.github_token
token_source = if ENV["GITHUB_TOKEN"].to_s.empty?
                 "GH_TOKEN"
               else
                 "GITHUB_TOKEN"
               end

if repo_slug.to_s.empty?
  abort("add_issues_to_release: missing GITHUB_REPOSITORY")
end
abort("add_issues_to_release: missing GitHub token") if token.to_s.empty?

path = ARGV.fetch(0)
content = File.read(path)
pr_numbers = ReleaseNotesIssueLinks.pr_numbers_for_content(content, repo_slug)

warn(
  "add_issues_to_release: repo=#{repo_slug}, file=#{path}, " \
  "bytes=#{content.bytesize}, token_source=#{token_source}, " \
  "pr_count=#{pr_numbers.length}"
)
warn(
  "add_issues_to_release: PR numbers: #{pr_numbers.join(', ')}"
) if pr_numbers.any?

linked_issues =
  ReleaseNotesIssueLinks.fetch_pr_linked_issues(
    repo_slug,
    pr_numbers,
    token: token,
    context: "add_issues_to_release"
  )

unless linked_issues
  abort("add_issues_to_release: failed to fetch linked issues")
end

File.write(
  path,
  ReleaseNotesIssueLinks.append_issues_under_pr_lines(
    content,
    repo_slug,
    linked_issues
  )
)
