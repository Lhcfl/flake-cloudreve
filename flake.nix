{
  description = "Cloudreve packaged for Nix, with a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  # Recommended binary caches. Honoured when the consumer enables
  # `accept-flake-config = true`.
  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://lhcfl.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "lhcfl.cachix.org-1:hf4kin1zCbaeLWygZlwhYms/oqB0I8/8ZZsPkezpFms="
    ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, self', ... }:
        let
          lib = pkgs.lib;

          # Starts the server against a throwaway SQLite database and checks that
          # the binary runs, that the version/commit were injected via ldflags,
          # and that the web frontend is actually embedded. Without the embed
          # check a build with a missing/broken assets.zip would still "succeed"
          # and only fail at runtime.
          smokeTest =
            {
              name,
              package,
              version,
              commit ? null,
            }:
            pkgs.runCommand "${name}-smoke-test"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.gnugrep
                ];
              }
              ''
                binary=${lib.getExe package}

                echo "=== checking embedded frontend ==="
                for marker in assets/build/index.html assets/build/version.json assets/build/sw.js; do
                  grep -qa -- "$marker" "$binary"
                  echo "  found $marker"
                done

                echo "=== starting server ==="
                mkdir -p data
                cat > conf.ini <<EOF
                [System]
                Mode = master
                Listen = 127.0.0.1:0
                SessionSecret = abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab
                LogLevel = error
                [Database]
                Type = sqlite
                DBFile = $PWD/data/cloudreve.db
                EOF

                timeout 30 "$binary" server -c "$PWD/conf.ini" > server.log 2>&1 || true
                tail -5 server.log

                grep -q -- "V${version}" server.log
                ${lib.optionalString (commit != null) ''
                  grep -q -- "Commit #${commit}" server.log
                ''}

                touch $out
              '';
        in
        {
          packages = {
            cloudreve = pkgs.callPackage ./packages/cloudreve.nix { };
            cloudreve-bin = pkgs.callPackage ./packages/cloudreve-bin.nix { };
            default = self'.packages.cloudreve;
          };

          checks = {
            cloudreve = smokeTest {
              name = "cloudreve";
              package = self'.packages.cloudreve;
              version = self'.packages.cloudreve.version;
              commit = self'.packages.cloudreve.commit;
            };

            cloudreve-bin = smokeTest {
              name = "cloudreve-bin";
              package = self'.packages.cloudreve-bin;
              version = self'.packages.cloudreve-bin.version;
            };
          };

          formatter = pkgs.nixfmt-tree;

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              curl
              gawk
              gnused
              jq
              nix-update
              nixd
              nixfmt-tree
            ];
          };
        };

      flake = {
        overlays.default = final: _prev: {
          cloudreve = final.callPackage ./packages/cloudreve.nix { };
          cloudreve-bin = final.callPackage ./packages/cloudreve-bin.nix { };
        };

        nixosModules.default = import ./modules/cloudreve.nix;
        nixosModules.cloudreve = import ./modules/cloudreve.nix;
      };
    };
}
