#!/usr/bin/env ruby
# frozen_string_literal: true

require "erb"
require "json"
require "net/http"
require "optparse"
require "pathname"
require "uri"
require "yaml"

ROOT = Pathname.new(__dir__).parent
FORMULAE = ROOT.join("Formula")
TARGETS = {
  "macos" => {
    "arm" => { "os" => "darwin", "arch" => "arm64", "requirement" => "arm64" },
    "intel" => { "os" => "darwin", "arch" => "amd64", "requirement" => "x86_64" }
  },
  "linux" => {
    "arm" => { "os" => "linux", "arch" => "arm64", "requirement" => "arm64" },
    "intel" => { "os" => "linux", "arch" => "amd64", "requirement" => "x86_64" }
  }
}.freeze

class GitHub
  API = "https://api.github.com"

  def initialize(token)
    @token = token
  end

  def releases(repository)
    get_json("#{API}/repos/#{repository}/releases?per_page=100")
      .reject { |release| release.fetch("draft") || release.fetch("prerelease") }
  end

  def text(url)
    request(url).body
  end

  private

  def get_json(url)
    JSON.parse(request(url).body)
  end

  def request(url, redirects = 5)
    raise "too many redirects for #{url}" if redirects.zero?

    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/vnd.github+json"
    if uri.hostname == "api.github.com" && @token && !@token.empty?
      request["Authorization"] = "Bearer #{@token}"
    end
    request["User-Agent"] = "roshbhatia-homebrew-tap"
    response = Net::HTTP.start(
      uri.hostname,
      uri.port,
      use_ssl: true,
      open_timeout: 10,
      read_timeout: 30
    ) { |http| http.request(request) }
    return request(response.fetch("location"), redirects - 1) if response.is_a?(Net::HTTPRedirection)

    unless response.is_a?(Net::HTTPSuccess)
      raise "GET #{url} returned #{response.code}: #{response.body}"
    end

    response
  end
end

def formula_class_name(name)
  name.split(/[-_]/).map(&:capitalize).join
end

def archive_name(package, version, target)
  values = target.merge("version" => version)
  package.fetch("archive").gsub(/%\{([^}]+)\}/) do
    values.fetch(Regexp.last_match(1))
  end
end

def targets_for(package)
  configured = package["targets"]
  return TARGETS unless configured

  configured.to_h do |system, architectures|
    available = TARGETS.fetch(system) { raise "#{package.fetch("name")}: unknown target system #{system}" }
    selected = architectures.to_h do |architecture|
      [architecture, available.fetch(architecture) do
        raise "#{package.fetch("name")}: unknown #{system} architecture #{architecture}"
      end]
    end
    [system, selected]
  end
end

def assets_by_name(release)
  release.fetch("assets").to_h { |asset| [asset.fetch("name"), asset] }
end

def complete_release(github, package)
  github.releases(package.fetch("repository")).find do |release|
    version = release.fetch("tag_name").delete_prefix("v")
    assets = assets_by_name(release)
    archives = targets_for(package).values.flat_map(&:values).map do |target|
      archive_name(package, version, target)
    end
    checksums = if package.fetch("checksum") == "sidecar"
                  archives.map { |archive| "#{archive}.sha256" }
                else
                  [package.fetch("checksum")]
                end
    (archives + checksums).all? { |name| assets.key?(name) }
  end
end

def checksum_map(github, package, assets)
  checksum_name = package.fetch("checksum")
  return {} if checksum_name == "sidecar"

  checksum_asset = assets.fetch(checksum_name) do
    raise "#{package.fetch("name")}: release has no #{checksum_name}"
  end
  github.text(checksum_asset.fetch("browser_download_url")).lines.to_h do |line|
    checksum, filename = line.split
    [filename, checksum]
  end
end

def artifact(github, package, assets, checksums, archive)
  asset = assets.fetch(archive) { raise "#{package.fetch("name")}: release has no #{archive}" }
  sha256 = if package.fetch("checksum") == "sidecar"
             sidecar = assets.fetch("#{archive}.sha256") do
               raise "#{package.fetch("name")}: release has no #{archive}.sha256"
             end
             github.text(sidecar.fetch("browser_download_url")).split.first
           else
             checksums.fetch(archive) { raise "#{package.fetch("name")}: checksum missing for #{archive}" }
           end
  raise "#{package.fetch("name")}: invalid SHA-256 for #{archive}" unless sha256.match?(/\A[0-9a-f]{64}\z/)

  { "url" => asset.fetch("browser_download_url"), "sha256" => sha256 }
end

def render_formula(github, package, release, template)
  version = release.fetch("tag_name").delete_prefix("v")
  assets = assets_by_name(release)
  checksums = checksum_map(github, package, assets)
  artifacts_by_system = targets_for(package).transform_values do |architectures|
    architectures.transform_values do |target|
      archive = archive_name(package, version, target)
      artifact(github, package, assets, checksums, archive)
        .merge("requirement" => target.fetch("requirement"))
    end
  end
  fallback_artifact = artifacts_by_system.values.find(&:one?)&.values&.first
  package = package.merge("class_name" => formula_class_name(package.fetch("name")))
  release = { "version" => version }
  context = binding
  context.local_variable_set(:systems, artifacts_by_system)
  ERB.new(template, trim_mode: "-").result(context)
end

if $PROGRAM_NAME == __FILE__
  options = { check: false, names: [] }
  OptionParser.new do |parser|
    parser.banner = "Usage: hack/update.rb [--check] [PACKAGE ...]"
    parser.on("--check", "Fail if generated formulae are stale") { options[:check] = true }
  end.parse!(into: options)
  options[:names] = ARGV

  manifest = YAML.safe_load(ROOT.join("packages.yml").read, permitted_classes: [], aliases: false)
  packages = manifest.fetch("packages")
  unless options[:names].empty?
    unknown = options[:names] - packages.map { |package| package.fetch("name") }
    abort "unknown package: #{unknown.join(", ")}" unless unknown.empty?
    packages = packages.select { |package| options[:names].include?(package.fetch("name")) }
  end

  github = GitHub.new(ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"])
  template = ROOT.join("templates/formula.rb.erb").read
  changes = []
  skipped = []
  rendered_formulae = {}

  packages.each do |package|
    release = complete_release(github, package)
    unless release
      if package["pending"]
        skipped << package.fetch("name")
        next
      end
      abort "#{package.fetch("name")}: no release contains all configured platform archives"
    end

    destination = FORMULAE.join("#{package.fetch("name")}.rb")
    rendered = render_formula(github, package, release, template)
    next if destination.exist? && destination.read == rendered

    changes << destination.relative_path_from(ROOT).to_s
    rendered_formulae[destination] = rendered
  end

  warn "Skipped pending packages without a complete release: #{skipped.join(", ")}" unless skipped.empty?
  abort "stale formulae: #{changes.join(", ")}" if options[:check] && !changes.empty?

  unless options[:check]
    FORMULAE.mkpath
    rendered_formulae.each { |destination, rendered| destination.write(rendered) }
  end
  puts(changes.empty? ? "Formulae are current" : "Updated #{changes.join(", ")}")
end
