{
  description = "Homebrew package generation checks";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs =
    { self, nixpkgs }:
    let
      each = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      devShells = each (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            ruby
            nixfmt
            python3
            gh
            git
          ];
        };
      });
      checks = each (system: {
        generator =
          nixpkgs.legacyPackages.${system}.runCommand "tap-generator-tests"
            {
              nativeBuildInputs = with nixpkgs.legacyPackages.${system}; [
                ruby
                python3
              ];
            }
            ''
              ruby ${self}/test/update_test.rb
              python3 ${self}/hack/test_update_flakes.py
              touch "$out"
            '';
      });
      formatter = each (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "tap-format";
          runtimeInputs = [
            pkgs.fd
            pkgs.nixfmt
          ];
          text = ''exec fd --extension nix --type file --exec-batch nixfmt "$@"'';
        }
      );
    };
}
