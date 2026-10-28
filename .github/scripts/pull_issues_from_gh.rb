#!/usr/bin/env ruby

require "json"
require "net/http"
require "set"
require "uri"

module ReleaseNotesIssueLinks
  module_function

  def github_token
    ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"]
  end

  def debug_enabled?
    ENV["RELEASE_NOTES_DEBUG"] == "1"
  end

  def debug(context, message)
    warn("#{context}: #{message}") if debug_enabled?
  end

  def post_graphql(query, token:, context:)
    uri = URI("https://api.github.com/graphql")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Accept"] = "application/vnd.github+json"
    request["Content-Type"] = "application/json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request.body = JSON.dump({ query: query })

    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        warn(
          "#{context}: GraphQL request failed with HTTP #{response.code} " \
          "#{response.message}"
        )
        warn("#{context}: response body: #{response.body.to_s[0, 1000]}")
        return nil
      end

      payload = JSON.parse(response.body)
      if payload["errors"]
        warn(
          "#{context}: GraphQL errors: " \
          "#{payload['errors'].map { |error| error['message'] }.join(', ')}"
        )
        debug(
          context,
          "GraphQL error payload: #{JSON.pretty_generate(payload)}"
        )
        return nil
      end

      payload
    end
  rescue StandardError => error
    warn(
      "#{context}: GraphQL request failed: #{error.class}: #{error.message}"
    )
    nil
  end

  def pr_number_from_line(line, repo_slug)
    explicit = line.match(
      %r{https://github\.com/#{Regexp.escape(repo_slug)}/pull/(\d+)}
    )
    return explicit[1].to_i if explicit

    trailing = line.match(/\(#(\d+)\)(?!.*#\d+)/)
    trailing && trailing[1].to_i
  end

  def pr_numbers_for_content(content, repo_slug)
    content.each_line.map { |line| pr_number_from_line(line, repo_slug) }
           .compact
           .uniq
  end

  def fetch_pr_linked_issues(repo_slug, pr_numbers, token: github_token,
                             context: "pull_issues_from_gh")
    if token.to_s.empty?
      warn("#{context}: missing GitHub token")
      return nil
    end

    if repo_slug.to_s.empty?
      warn("#{context}: missing repository slug")
      return nil
    end

    if pr_numbers.empty?
      warn("#{context}: no PR numbers found in release body; nothing to fetch")
      return {}
    end

    owner, repo = repo_slug.split("/", 2)
    if owner.to_s.empty? || repo.to_s.empty?
      warn("#{context}: invalid repository slug: #{repo_slug.inspect}")
      return nil
    end

    results = {}
    debug(
      context,
      "fetching linked issues for #{pr_numbers.length} PR(s): " \
      "#{pr_numbers.join(', ')}"
    )

    pr_numbers.each_slice(25) do |batch|
      debug(context, "querying PR batch: #{batch.join(', ')}")
      pr_queries = batch.map do |number|
        <<~GRAPHQL
          pr_#{number}: pullRequest(number: #{number}) {
            closingIssuesReferences(first: 20) {
              nodes {
                number
                title
                url
                state
              }
            }
          }
        GRAPHQL
      end.join("\n")

      query = <<~GRAPHQL
        query {
          repository(owner: "#{owner}", name: "#{repo}") {
            #{pr_queries}
          }
        }
      GRAPHQL

      payload = post_graphql(query, token: token, context: context)
      return nil unless payload

      repository = payload.dig("data", "repository")
      unless repository
        warn(
          "#{context}: GraphQL response did not include repository data for " \
          "#{repo_slug}"
        )
        debug(
          context,
          "GraphQL response payload: #{JSON.pretty_generate(payload)}"
        )
        return nil
      end

      batch.each do |number|
        nodes = repository.dig("pr_#{number}", "closingIssuesReferences",
                               "nodes") || []
        debug(
          context,
          "PR ##{number}: #{nodes.compact.length} linked issue(s) returned"
        )
        issues = nodes.compact.map do |node|
          next unless node["number"] && node["title"] && node["url"]

          {
            number: node["number"],
            title: node["title"],
            url: node["url"],
            state: node["state"].to_s.downcase
          }
        end.compact

        results[number] = issues if issues.any?
      end
    end

    results
  end

  def format_issue_line(issue)
    "#{issue[:title]} [##{issue[:number]}](#{issue[:url]})"
  end

  def append_issues_under_pr_lines(content, repo_slug, linked_issues)
    seen_issue_lines = Hash.new { |hash, key| hash[key] = Set.new }
    output_lines = []

    content.each_line do |line|
      output_lines << line

      pr_number = pr_number_from_line(line, repo_slug)
      next unless pr_number

      issues = linked_issues[pr_number]
      next if issues.nil? || issues.empty?

      issues.each do |issue|
        formatted = format_issue_line(issue)
        next if seen_issue_lines[pr_number].include?(formatted)

        seen_issue_lines[pr_number] << formatted
        output_lines << "  - #{formatted}\n"
      end
    end

    output_lines.join
  end
end
