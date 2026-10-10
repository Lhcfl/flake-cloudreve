# AGENTS.md

Instructions for automated agents (and humans) working in this repository.

## What this repo is

A Nix flake that packages [Cloudreve](https://cloudreve.org) and provides a
NixOS module. It is built with
[flake-parts](https://github.com/hercules-ci/flake-parts) and exports four
systems.

Primary deliverables:

- `packages.<system>.cloudreve` — Cloudreve built from source (Go backend + web
  frontend). This is the **default** package.
- `packages.<system>.cloudreve-bin` — Cloudreve repackaged from the official
  GitHub release binary.
- `nixosModules.default` / `nixosModules.cloudreve` — the `services.cloudreve`
  NixOS module.
- `overlays.default` — adds `pkgs.cloudreve` and `pkgs.cloudreve-bin`.

## Hard rules

### Do not store secrets in the Nix store

Database passwords (and similar secrets) must go through
`services.cloudreve.database.passwordFile`. Never bake them into
`settings`/`database.password`.

## Layout

```
flake.nix                  flake-parts entry point: packages, overlay, nixosModules
packages/cloudreve.nix     from-source build (default)
packages/cloudreve-bin.nix prebuilt release repackaging
modules/cloudreve.nix      the actual NixOS module
scripts/update.sh          release updater used by the Update workflow
.github/workflows/ci.yml   build + Cachix on push/PR
.github/workflows/update.yml  scheduled nix-update pull request
README.md                  English documentation
README.zh_CN.md            Chinese documentation
LICENSE                    MIT license (packaging code)
```

## Conventions

- Keep `packages.<system>.cloudreve` as the from-source build and
  `packages.<system>.cloudreve-bin` as the prebuilt release. Keep
  `packages.<system>.default` pointing at `cloudreve`.
- The NixOS module's `package` option defaults to
  `pkgs.callPackage ../packages/cloudreve.nix { }` (the from-source package) so
  the module works without the overlay.
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
- `cloudreve-bin` is a prebuilt upstream release, so leave
  `sourceProvenance = [ lib.sourceTypes.binaryNativeCode ]` and do not add a
  `buildGoModule` build there.
- `cloudreve` builds the frontend from the `cloudreve/frontend` submodule
  revision pinned by the Cloudreve tag. When bumping the version, update
  `frontendRev` to the submodule revision, otherwise the embedded frontend will
  not match the backend.
- Keep `README.md` and `README.zh_CN.md` content in sync when changing options.

## Fixed-output hashes for the from-source build

The `cloudreve` package depends on fixed-output derivations whose hashes cannot
be computed without first fetching or building:

- `fetchFromGitHub` hashes for the Cloudreve and frontend sources — obtainable
  with `nix-prefetch-url --unpack` (convert with
  `nix-hash --to-sri --type sha256 <base32>`).
- `fetchYarnDeps` hash (`offlineCache`) — only known after downloading the npm
  tarballs once.
- `vendorHash` — only known after `go mod vendor` runs once.

Until these are filled in, the package uses `lib.fakeHash` and the build fails
with a hash mismatch. `scripts/update.sh` (and the Update workflow) uses
[nix-update](https://github.com/Mic92/nix-update) to compute `vendorHash` and
the Yarn `offlineCache` hash, so it can fill them automatically. The CI job
summary can also be used to read them from a failing build.

The intended manual workflow is:

1. Push with the placeholder hashes.
2. Read the expected hashes from the CI job summary / logs (or run
   `nix develop -c scripts/update.sh`).
3. Fill them into `packages/cloudreve.nix` and push again.

`fetchYarnDeps` uses a lockfile with `registry.npmjs.org` URLs rewritten to
`registry.yarnpkg.com` (see `patchedYarnLock`), because the Nix build sandbox
cannot reliably reach `registry.npmjs.org`. Keep that rewrite when touching the
frontend dependency handling, and keep the lockfile used for the offline cache
identical to the one used during the build (the assets derivation copies it in
`postPatch`, and `yarnConfigHook` diffs them).

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

Build the packages (the binary package is quick; the from-source package is
heavy):

```console
$ nix build .#cloudreve-bin --no-link
$ nix build .#cloudreve --no-link
$ nix run .#cloudreve-bin -- server --help
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

## CI / Cachix

`.github/workflows/ci.yml` builds both packages on `x86_64-linux` and
`aarch64-linux` and pushes results to the `lhcfl` Cachix cache via
`cachix/cachix-action`. Add the repository secret `CACHIX_AUTH_TOKEN` (a Cachix
auth token with write access to `lhcfl`) to enable pushing; without it, pushes
are skipped.

The flake's `nixConfig` recommends the `nix-community` and `lhcfl` caches as
`extra-substituters` with their public keys. Keep those in sync with the cache
name used by CI.

## Automatic updates

`scripts/update.sh` updates the packages
(`bin`, `src` or both) using [nix-update](https://github.com/Mic92/nix-update):

- `cloudreve-bin`: `version` plus every per-platform hash, read from the
  release's `checksums.txt` (nix-update can only prefetch the hash of the
  system it runs on, hence the checksums approach).
- `cloudreve`: `version`, `rev`, `commit`, the pinned `frontendRev` and the
  source hashes, followed by `nix-update cloudreve --flake --version=skip` to
  refresh `vendorHash` and `offlineCache`.

`.github/workflows/update.yml` runs the script daily and on manual dispatch and
opens/updates a pull request. `nix-update` and the other tools are provided by
the flake's dev shell (`nix develop -c scripts/update.sh`). The repository
setting *Allow GitHub Actions to create and approve pull requests* must be
enabled for the PR to be created.

## Updating Cloudreve

1. Choose a new tag at <https://github.com/cloudreve/Cloudreve/releases>.
2. `packages/cloudreve-bin.nix`: update `version` and every entry in `sources`.
3. `packages/cloudreve.nix`: update `version`, `rev`, `commit`, `frontendRev`
   and the fixed-output hashes.
4. Re-run `nix build .#cloudreve-bin`, `nix build .#cloudreve` and the module
   evaluation above.

Source hashes can be recomputed with `nix-prefetch-url --unpack` on the archive
URLs; release hashes come from the release's `checksums.txt` or
`nix store prefetch-file`.

## Upstream references

- Documentation: <https://docs.cloudreve.org/zh/>
- Configuration reference: <https://docs.cloudreve.org/zh/overview/configure>
- Releases: <https://github.com/cloudreve/Cloudreve/releases>
