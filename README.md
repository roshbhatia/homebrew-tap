# Homebrew tap

Install the command-line tools on macOS or Linux:

```sh
brew install roshbhatia/tap/changes
brew install roshbhatia/tap/changes roshbhatia/tap/changes-provider-git-notes
brew install roshbhatia/tap/changes-all
```

The first command installs the core. The second adds one provider; name more packages to select several.
The `-all` bundle depends on the core and every package in that release's extras index.
It installs no duplicate copies of the binaries.

The same choices apply to Ask, Gate, Orc, Seshy, Tether, and Traces.
Agent-notes and Specutil have standalone formulae.
The WezTerm zoxide adapter is `sysinit-wezterm-provider-zoxide`.

Provider formulae install manifests under Homebrew's shared data directory.
Core wrappers add that directory to `XDG_DATA_DIRS` and preserve the caller's other data directories.
Provider packages include declared runtime dependencies. Some agent CLIs and desktop applications need a separate installation and authentication.
Each extra's README lists those requirements.

New provider formulae appear when the utility publishes a release with its package index and all platform archives.
Formula generation rejects a partial indexed release.

## Maintenance

`packages.yml` defines package metadata and archive layouts. Run the updater to
resolve the newest complete GitHub release and render each formula:

```sh
GH_TOKEN="$(gh auth token)" ./hack/update.rb
GH_TOKEN="$(gh auth token)" ./hack/update.rb --check
GH_TOKEN="$(gh auth token)" ./hack/update.rb traces
```

The scheduled update workflow runs every six hours. It commits refreshed
formulae with this repository's `GITHUB_TOKEN`. Source repositories do not need
a tap token.
