{
  description = "Cloudreve packaged for Nix, with a NixOS module";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
        };

        nixosModules.default = import ./modules/cloudreve.nix;
        nixosModules.cloudreve = import ./modules/cloudreve.nix;
      };
    };
}
