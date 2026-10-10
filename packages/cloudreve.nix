{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  fetchYarnDeps,
  yarnConfigHook,
  yarnBuildHook,
  nodejs,
  jq,
  zip,
  runCommandLocal,
  # Version of Cloudreve to build. Keep in sync with the frontend revision below.
  version ? "4.19.1",
  # Git tag/commit of cloudreve/Cloudreve to build.
  rev ? version,
  # Short commit of cloudreve/Cloudreve, injected into the binary.
  commit ? "a8becb9",
  # Submodule revision of cloudreve/frontend pinned by the Cloudreve tag above.
  frontendRev ? "19da0fe1ecd40971fafa813983d769fdce41573c",
}:

let
  cloudreveSrc = fetchFromGitHub {
    owner = "cloudreve";
    repo = "Cloudreve";
    rev = rev;
    hash = "sha256-55itxJOIZvhbVw2hFMokLdt1Xja9hoZMpABOd7Shavs=";
  };

  frontendSrc = fetchFromGitHub {
    owner = "cloudreve";
    repo = "frontend";
    rev = frontendRev;
    hash = "sha256-/NXfefR3cKS5+02iuocJA0ncTISqYOskfkN8VFYgyag=";
  };

  # Some upstream lockfile entries point at registry.npmjs.org, which is not
  # reliably reachable from the build sandbox. Yarn's registry mirrors npm, so
  # rewrite those URLs; the lockfile integrity hashes still verify the content.
  patchedYarnLock = runCommandLocal "cloudreve-frontend-yarn.lock" { } ''
    sed 's#https://registry.npmjs.org/#https://registry.yarnpkg.com/#g' \
      ${frontendSrc}/yarn.lock > $out
  '';

  # Builds the SPA and packs it into the assets.zip that the Go binary embeds.
  assets = stdenv.mkDerivation {
    pname = "cloudreve-assets";
    inherit version;

    src = frontendSrc;

    nativeBuildInputs = [
      jq
      nodejs
      yarnConfigHook
      yarnBuildHook
      zip
    ];

    offlineCache = fetchYarnDeps {
      yarnLock = patchedYarnLock;
      hash = "sha256-6mRSovoYTngrlkyCO2sjqukjQ8v7DhGWJjlxN59l8VU=";
    };

    # The release script runs `yarn version --new-version <version>`, which needs
    # a git repository. Patch package.json directly instead; the version is read
    # by vite from npm_package_version during the build.
    postPatch = ''
      cp -f ${patchedYarnLock} yarn.lock

      jq '.version = "${version}"' package.json > package.json.new
      mv package.json.new package.json
    '';

    NODE_OPTIONS = "--max-old-space-size=8192";

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      zip -rq "$out/assets.zip" assets/build

      runHook postInstall
    '';

    meta = {
      description = "Web frontend bundle embedded into Cloudreve";
      homepage = "https://cloudreve.org";
      license = lib.licenses.gpl3Only;
    };
  };
in
buildGoModule {
  pname = "cloudreve";
  inherit version;

  src = cloudreveSrc;

  # Cloudreve uses the pure-Go modernc.org/sqlite driver, so CGO is not needed.
  env.CGO_ENABLED = 0;

  vendorHash = lib.fakeHash;

  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/cloudreve/Cloudreve/v4/application/constants.BackendVersion=${version}"
    "-X github.com/cloudreve/Cloudreve/v4/application/constants.LastCommit=${commit}"
  ];

  preBuild = ''
    install -Dm644 ${assets}/assets.zip application/statics/assets.zip
  '';

  # `go install` names the binary after the import path ("Cloudreve").
  postInstall = ''
    if [ -e "$out/bin/Cloudreve" ]; then
      mv "$out/bin/Cloudreve" "$out/bin/cloudreve"
    fi
  '';

  meta = {
    description = "Self-hosted file management and sharing system (built from source)";
    longDescription = ''
      Cloudreve is a self-hosted file management and sharing system that
      supports multiple storage backends (local, S3, OneDrive, Google Drive,
      ...) and can be used as a personal cloud drive or a shared file hosting
      platform.

      This package builds Cloudreve from source, including the web frontend.
    '';
    homepage = "https://cloudreve.org";
    downloadPage = "https://github.com/cloudreve/Cloudreve/releases";
    changelog = "https://github.com/cloudreve/Cloudreve/releases/tag/${version}";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.unix;
    mainProgram = "cloudreve";
  };
}
