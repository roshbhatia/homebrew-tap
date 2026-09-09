# frozen_string_literal: true

require "minitest/autorun"

require_relative "../hack/update"

class FakeGitHub
  def initialize(checksums)
    @checksums = checksums
  end

  def text(url)
    @checksums.fetch(url)
  end
end

class UpdateTest < Minitest::Test
  def test_downloads_use_asset_headers_and_keep_tokens_on_the_api_host
    requests = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      requests << request
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.define_singleton_method(:body) { "ok" }
      response
    end
    transport = lambda do |*_, **_, &block|
      block.call(http)
    end
    Net::HTTP.stub(:start, transport) do
      github = GitHub.new("test-token")
      github.text("https://api.github.com/repos/example/tool/releases")
      github.text("https://github.com/example/tool/releases/download/v1/tool.sha256")
    end
    assert_equal "application/vnd.github+json", requests[0]["Accept"]
    assert_equal "Bearer test-token", requests[0]["Authorization"]
    assert_equal "*/*", requests[1]["Accept"]
    assert_nil requests[1]["Authorization"]
  end

  FIXTURE = YAML.safe_load(
    ROOT.join("test/fixtures/orc-release.yml").read,
    permitted_classes: [],
    aliases: false
  ).freeze

  def test_orc_formula_matches_release_archive_contract
    package = package_named("orc")
    version = FIXTURE.fetch("version")
    assets = fixture_assets
    checksum = "a" * 64
    checksums = FIXTURE.fetch("archives").to_h do |archive|
      sidecar_url = assets.fetch("#{archive.fetch("name")}.sha256").fetch("browser_download_url")
      [sidecar_url, "#{checksum}  #{archive.fetch("name")}\n"]
    end
    release = {
      "tag_name" => "v#{version}",
      "assets" => assets.values,
      "draft" => false,
      "prerelease" => false
    }

    expected_archives = FIXTURE.fetch("archives").map { |archive| archive.fetch("name") }
    actual_archives = targets_for(package).values.flat_map(&:values).map do |target|
      archive_name(package, version, target)
    end
    assert_equal expected_archives.sort, actual_archives.sort

    formula = render_formula(
      FakeGitHub.new(checksums),
      package,
      release,
      ROOT.join("templates/formula.rb.erb").read
    )

    expected_archives.each do |archive|
      assert_includes formula, "https://github.com/roshbhatia/orc/releases/download/v#{version}/#{archive}"
    end
    assert_match(/homepage .*\n  url .*darwin_arm64.*\n  sha256 .*\n  license/, formula)
    assert_match(/on_macos do\n    depends_on arch: :arm64\n\n    on_arm do/, formula)
    refute_includes formula, "orc_#{version}_darwin_amd64.tar.gz"
    assert_includes formula, %(archive_root = Dir["orc_#{version}_*_*"])
    assert_includes formula, ".find { |path| File.directory?(path) } || buildpath"
    assert_includes formula, %(libexec.install "\#{archive_root}/bin/orc")

    FIXTURE.fetch("archives").each do |archive|
      assert_match(/\Aorc_#{Regexp.escape(version)}_(darwin|linux)_(arm64|amd64)\/bin\/orc\z/,
                   archive.fetch("binary"))
      assert_equal "#{archive.fetch("root")}/bin/orc", archive.fetch("binary")
    end
  end

  def test_provider_index_installs_shared_manifests
    core = package_named("traces")
    entry = {
      "name" => "traces-provider-codex", "kind" => "provider",
      "binary" => "traces-provider-codex", "archive" => "traces_provider_codex_%{version}_%{os}_%{arch}.tar.gz",
      "share" => ["share/traces/providers/codex/provider.yaml"]
    }
    archives = targets_for(core).values.flat_map(&:values).map { |target| archive_name(entry, "1.0.0", target) }
    assets = ["package-index.json", "checksums.txt", *archives].map { |name| {"name" => name, "browser_download_url" => name} }
    github = FakeGitHub.new({
      "package-index.json" => JSON.generate({"version" => 1, "packages" => [entry]}),
      "checksums.txt" => archives.map { |name| "#{'a' * 64}  #{name}\n" }.join
    })
    release = {"tag_name" => "v1.0.0", "assets" => assets}
    packages = provider_packages(github, core, release)
    assert_equal [entry["name"]], packages.map { |package| package["name"] }
    refute packages[0].key?("completions")
    formula = render_formula(github, packages[0], release, ROOT.join("templates/formula.rb.erb").read)
    assert_includes formula, '(share/"traces/providers/codex").install "share/traces/providers/codex/provider.yaml"'
    assert_includes formula, 'bin.install "traces-provider-codex"'
    assert_equal [], provider_packages(github, core, {"assets" => []})
    assert_raises(RuntimeError) { provider_packages(github, core, release.merge("assets" => assets[0..1])) }
  end

  def test_core_wrapper_preserves_xdg_defaults
    package = package_named("orc")
    assert package.fetch("xdg_data")
    template = ROOT.join("templates/formula.rb.erb").read
    assert_includes template, 'XDG_DATA_DIRS="#{HOMEBREW_PREFIX}/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"'
  end

  def test_provider_runtime_installation_and_bundle_syntax
    core = package_named("traces")
    version = FIXTURE.fetch("version")
    assets = fixture_assets
    checksums = FIXTURE.fetch("archives").map { |archive| "#{'a' * 64}  #{archive.fetch('name')}\n" }.join
    release = { "tag_name" => "v#{version}", "assets" => assets.values + [{ "name" => "checksums.txt", "browser_download_url" => "checksums" }] }
    package = core.merge("archive" => "orc_%{version}_%{os}_%{arch}.tar.gz", "dependencies" => ["node", "git"], "npm_runtime" => "extras/calldiff/runtime")
    template = ROOT.join("templates/formula.rb.erb").read
    formula = render_formula(FakeGitHub.new("checksums" => checksums), package, release, template)
    assert_includes formula, 'depends_on "node"'
    assert_includes formula, 'system "npm", "ci", "--prefix", libexec/"runtime", "--legacy-peer-deps"'
    assert_includes formula, 'runtime/node_modules/.bin:$PATH'
    RubyVM::InstructionSequence.compile(formula)
    bundle = render_formula(FakeGitHub.new("checksums" => checksums), package.merge("bundle" => ["traces", "traces-provider-git"]), release, template)
    assert_includes bundle, 'depends_on "roshbhatia/tap/traces-provider-git"'
    refute_includes bundle, 'bin.install'
    RubyVM::InstructionSequence.compile(bundle)
  end

  private

  def package_named(name)
    manifest = YAML.safe_load(ROOT.join("packages.yml").read, permitted_classes: [], aliases: false)
    manifest.fetch("packages").find { |package| package.fetch("name") == name }
  end

  def fixture_assets
    version = FIXTURE.fetch("version")
    FIXTURE.fetch("archives").flat_map do |archive|
      name = archive.fetch("name")
      [name, "#{name}.sha256"]
    end.to_h do |name|
      url = "https://github.com/roshbhatia/orc/releases/download/v#{version}/#{name}"
      [name, { "name" => name, "browser_download_url" => url }]
    end
  end
end
