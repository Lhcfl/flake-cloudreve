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
        {
          packages = {
            cloudreve = pkgs.callPackage ./packages/cloudreve.nix { };
            cloudreve-bin = pkgs.callPackage ./packages/cloudreve-bin.nix { };
            default = self'.packages.cloudreve;
          };

          formatter = pkgs.nixfmt-tree;

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt-tree
              pkgs.nixd
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
