{
  lib,
  stdenvNoCC,
  fetchurl,
  # Version of Cloudreve to package. Bump this together with the hashes below.
  version ? "4.19.1",
}:

let
  # Upstream publishes self-contained Go binaries with the frontend embedded,
  # so this derivation simply repackages the official release tarballs. Hashes
  # are sha256 (SRI) of the tarballs from
  # https://github.com/cloudreve/Cloudreve/releases/tag/${version}
  sources = {
    x86_64-linux = {
      asset = "linux_amd64";
      hash = "sha256-KHofWa2xJJrxXNVQsZHS+nETK/0SX+rYV48gFSxLmd4=";
    };
    aarch64-linux = {
      asset = "linux_arm64";
      hash = "sha256-9V134OXri8aZqaa7Ehaw7jr6O/6NfJ1AXKmEUzmuew4=";
    };
    x86_64-darwin = {
      asset = "darwin_amd64";
      hash = "sha256-9N1pcxylLjk5mlTa2lqOyKa8uTmucKcEQfEYgqbicKA=";
    };
    aarch64-darwin = {
      asset = "darwin_arm64";
      hash = "sha256-pnV32mmnf9ESRvxmNgS27avzOSFJ23ZCQ7/PSW9YFiA=";
    };
  };

  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "cloudreve-bin: no prebuilt release for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cloudreve-bin";
  inherit version;

  src = fetchurl {
    url = "https://github.com/cloudreve/Cloudreve/releases/download/${version}/cloudreve_${version}_${source.asset}.tar.gz";
    hash = source.hash;
  };

  # The tarballs extract their files into the current directory, not a
  # versioned top-level folder.
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  # The upstream binaries are already stripped and, on Linux, statically linked.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 cloudreve $out/bin/cloudreve
    install -Dm644 LICENSE $out/share/licenses/cloudreve/LICENSE

    runHook postInstall
  '';

  meta = {
    description = "Self-hosted file management and sharing system";
    longDescription = ''
      Cloudreve is a self-hosted file management and sharing system that
      supports multiple storage backends (local, S3, OneDrive, Google Drive,
      ...) and can be used as a personal cloud drive or a shared file hosting
      platform.
    '';
    homepage = "https://cloudreve.org";
    downloadPage = "https://github.com/cloudreve/Cloudreve/releases";
    changelog = "https://github.com/cloudreve/Cloudreve/releases/tag/${version}";
    license = lib.licenses.gpl3Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "cloudreve";
  };
})
