# AGENTS.md

Instructions for automated agents (and humans) working in this repository.

## What this repo is

A Nix flake that packages [Cloudreve](https://cloudreve.org) and provides a
NixOS module. It is built with
[flake-parts](https://github.com/hercules-ci/flake-parts) and exports four
systems.

Primary deliverables:

- `packages.<system>.cloudreve` — the Cloudreve binary.
- `nixosModules.default` / `nixosModules.cloudreve` — the `services.cloudreve`
  NixOS module.
- `overlays.default` — adds `pkgs.cloudreve`.

## Hard rules

### Do not store secrets in the Nix store

Database passwords (and similar secrets) must go through
`services.cloudreve.database.passwordFile`. Never bake them into
`settings`/`database.password`.

## Layout

```
flake.nix                 flake-parts entry point: packages, overlay, nixosModules
packages/cloudreve.nix    callPackage function for the Cloudreve derivation
modules/cloudreve.nix     the actual NixOS module
README.md                 English documentation
README.zh_CN.md           Chinese documentation
```

## Conventions

- Keep `packages.<system>.cloudreve` as the canonical package name; keep
  `packages.<system>.default` pointing at it.
- The NixOS module's `package` option defaults to
  `pkgs.callPackage ../packages/cloudreve.nix { }` so the module works without the
  overlay.
- `services.cloudreve.settings` is deliberately `types.attrsOf types.str`, with
  flat `"Section.Key"` keys (e.g. `"System.Listen" = ":5212"`). Do not change
  this to a nested type without updating the READMEs and the option
  documentation.
- Values in `settings` that contain `#` or `;` are wrapped in backticks, because
  Cloudreve treats those characters as INI comments.
- `services.cloudreve.database.*` expands into the `[Database]` section and
  takes precedence over overlapping keys in `settings`.
- The `database.passwordFile` secret is injected at runtime through the
  `CR_CONF_Database__Password` environment variable (Cloudreve accepts `__` as
  a section/key separator, which keeps it a valid systemd env var name).
- The packaged binary is a prebuilt upstream release, so leave
  `sourceProvenance = [ lib.sourceTypes.binaryNativeCode ]` and do not add a
  `buildGoModule` build unless the release process changes.
- Keep `README.md` and `README.zh_CN.md` content in sync when changing options.

## Formatting

Format the tree with:

```console
$ nix fmt
```

The flake `formatter` is `pkgs.nixfmt-tree` (treefmt running `nixfmt` on
`*.nix`). `treefmt` derives its tree root from the git worktree and honours
`.gitignore` (so `.pi/` is skipped), which is why this repository is a git
repository. Run it inside this repository only and never point it at a large
tree such as `/nix/store`.

## Verification commands

Evaluate the flake without building everything:

```console
$ nix flake check --no-build
```

Build the package for the current system:

```console
$ nix build .#cloudreve --no-link
$ nix run .#cloudreve -- server --help
```

Evaluate the NixOS module (evaluates assertions and the whole config):

```console
$ nix eval --impure --raw --expr '
let
  flake = builtins.getFlake (toString ./.);
  nixpkgs = flake.inputs.nixpkgs;
  ev = nixpkgs.lib.nixosSystem {
    modules = [
      flake.nixosModules.default
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        services.cloudreve.enable = true;
        services.cloudreve.settings."System.Listen" = "127.0.0.1:5212";
        system.stateVersion = "25.11";
        fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
        boot.loader.grub.devices = [ "nodev" ];
      }
    ];
  };
in builtins.toString ev.config.system.build.toplevel.drvPath
'
```

To inspect the generated `conf.ini`, evaluate the service unit derivation and
build it (the unit file references the config file), then read the resulting
`*-cloudreve.conf.ini` from the store:

```console
$ nix eval --impure --raw --expr '... in builtins.toString ev.config.systemd.units."cloudreve.service".unit.drvPath'
$ nix-store -r <that .drv>
```

## Updating Cloudreve

1. Choose a new tag at <https://github.com/cloudreve/Cloudreve/releases>.
2. Update `version` and every entry in `sources` in `packages/cloudreve.nix`.
3. Hashes are sha256 of the release tarballs. Get them from the release's
   `checksums.txt` or with:

```console
$ nix store prefetch-file --json --hash-type sha256 \
    https://github.com/cloudreve/cloudreve/releases/download/<version>/cloudreve_<version>_<asset>.tar.gz
```

   Use the `hash` field (SRI) in `sources`.

4. Re-run `nix build .#cloudreve` and the module evaluation above.

## Upstream references

- Documentation: <https://docs.cloudreve.org/zh/>
- Configuration reference: <https://docs.cloudreve.org/zh/overview/configure>
- Releases: <https://github.com/cloudreve/Cloudreve/releases>
