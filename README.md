# Homebrew tap

Install the command-line tools on macOS or Linux:

```sh
brew install roshbhatia/tap/ask
brew install roshbhatia/tap/changes
brew install roshbhatia/tap/traces
brew install roshbhatia/tap/specutil
brew install roshbhatia/tap/seshy
```

Orc will join this list after its release contains binaries for macOS and Linux
on both Intel and Arm. After that release finishes, add it with one command:

```sh
GH_TOKEN="$(gh auth token)" ./hack/update.rb orc
```

The formulae install Bash, Zsh, Fish, and Nushell completions. They use the
native release archive for the current operating system and architecture.

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
