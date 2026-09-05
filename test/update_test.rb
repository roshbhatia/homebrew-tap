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
    refute_includes formula, "orc_#{version}_darwin_amd64.tar.gz"
    assert_includes formula, %(archive_root = Dir["orc_#{version}_*_*"])
    assert_includes formula, ".find { |path| File.directory?(path) }"
    assert_includes formula, %(bin.install "\#{archive_root}/bin/orc")

    FIXTURE.fetch("archives").each do |archive|
      assert_match(/\Aorc_#{Regexp.escape(version)}_(darwin|linux)_(arm64|amd64)\/bin\/orc\z/,
                   archive.fetch("binary"))
      assert_equal "#{archive.fetch("root")}/bin/orc", archive.fetch("binary")
    end
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
