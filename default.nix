# Function which returns an attribute set
# of build recipe derivations for
# roc nightly compilers using sources.json.
{
  pkgs,
  system,
}: let
  # Parse sources.json to an object of nix attributes.
  inherit (pkgs) lib;
  sources = builtins.fromJSON (builtins.readFile ./sources.json);

  # Grab a particular nightly release from sources
  # and build a roc derivation for it.

  # individual release e.g.:
  # "nightly-2026-July-14-c9147c2": {
  #       "compilerCommit": "c9147c281f29182a5c715bee4c9e095b7a812292",
  #       "compilerVersion": "release-fast-c9147c28",
  #       "publishedAt": "2026-07-14T07:12:44Z",
  #       "systems": {
  #         "aarch64-darwin": {
  #           "asset": "roc_nightly-macos_apple_silicon-2026-07-14-c9147c2.tar.gz",
  #           "sha256": "sha256-5SSO3pKkUv0FXufP/GAVrs2u3m5gwA48K3lyWeQSHsI=",
  #           "url": "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-July-14-c9147c2/roc_nightly-macos_apple_silicon-2026-07-14-c9147c2.tar.gz"
  #         }
  #      },
  #      "tag": "nightly-2026-July-14-c9147c2"
  # }
  mkRoc = release: let
    # Use the source indexed by the target system, e.g.:
    # system:  "aarch64-darwin"
    # source:
    #         "aarch64-darwin": {
    #           "asset": "roc_nightly-macos_apple_silicon-2026-07-14-c9147c2.tar.gz",
    #           "sha256": "sha256-5SSO3pKkUv0FXufP/GAVrs2u3m5gwA48K3lyWeQSHsI=",
    #           "url": "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-July-14-c9147c2/roc_nightly-macos_apple_silicon-2026-07-14-c9147c2.tar.gz"
    #         },
    source = release.systems.${system};
  in
    pkgs.stdenv.mkDerivation {
      pname = "roc";
      version = release.tag;

      # Download nightly release tarball
      # Set sha256 for integrity and reproducibility
      # Nix downloads the archive and rejects it if its SHA-256
      # differs.
      src = pkgs.fetchurl {
        inherit (source) url;
        hash = source.sha256;
      };

      # Skip config, build, strip steps as we are not
      # actually building the compiler from source here.
      #
      # - dontConfigure skips standard config steps like
      # ./configure.
      # - dontBuild skips compilation i.e. "make"
      # - dontStrip prevents fixup hooks from removing
      #   symbols from prebuilt roc executable.
      dontConfigure = true;
      dontBuild = true;
      dontStrip = true;

      # A conditional for Linux:
      #   - If the host platform which will be running roc
      #     is Linux, make the wrapProgram available during
      #     package construction.
      #
      # Darwin uses different linking logic.
      nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.makeWrapper
      ];

      # preInstall/postInstall allow callers to
      # register shell code before or after installation.
      # If the caller doesn't register a runHook, they are noops.
      #
      # $out is its hashed location in the nix store.
      # e.g. /nix/store/<hash>-roc-nightly-2026-July-14-c9147c2
      # 755 gives binary read/write/exec permissions.
      # 644 gives license READ perms.
      installPhase = ''
        runHook preInstall

        install -Dm755 roc "$out/bin/roc"
        install -Dm644 LICENSE "$out/share/licenses/roc/LICENSE"
        install -Dm644 legal_details "$out/share/doc/roc/legal_details"

        # The archive's darwin directory contains the minimal
        # libSystem.tbd sysroot. Roc searches for this directory next
        # to its executable when linking macOS programs.
        ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
          cp -R darwin "$out/bin/darwin"
        ''}

        runHook postInstall
      '';

      # On Linux, wrap roc (which lives at PATH) in a
      # closure which contains coreutils and cc,
      # tools it needs.
      #
      # Darwin uses different linking strategy.
      postFixup = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
        # Adds the location of the coreutils and cc to roc's PATH
        # so it knows where to find them.
        wrapProgram "$out/bin/roc" \
          --prefix PATH : ${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.stdenv.cc
          ]
        }
      '';

      # Attach additional attributes to the resulting derivation
      # without changing how roc builds.
      #
      # Useful for checks/debugging/automation.
      # For ex. we use compilerVersion in our smoke test flake
      # check
      passthru = {
        inherit (release) compilerCommit compilerVersion tag;
        inherit source;
      };

      meta = {
        description = "Official Roc Zig new-compiler nightly binary";
        homepage = "https://github.com/roc-lang/nightlies";
        changelog = "https://github.com/roc-lang/nightlies/releases/tag/${release.tag}";
        license = lib.licenses.upl;
        mainProgram = "roc";
        platforms = [system];
        sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      };
    };

  # what does mapAttrs do? what does filterAttrs do?

  # what does this fn do?
  # 1. Removes releases unavailable for system via filterAttrs
  # 2. Converts every remaining release into a Roc package via mkRoc
  # 3. Preserves release tags as package names
  #
  # Result ex:
  #  {
  #   "nightly-2026-July-14-c9147c2" = <derivation>;
  #   "nightly-2026-July-15-c2d30e8" = <derivation>;
  # }
  releasePackages = lib.mapAttrs (_: mkRoc) (
    lib.filterAttrs (_: release: builtins.hasAttr system release.systems) sources.releases
  );

  nightly = releasePackages.${sources.latest};
in
  releasePackages
  # explain the // syntax
  // {
    inherit nightly;
    # default and nightly are the same currently because the new
    # Zig-based roc compiler has no stable releases yet.
    # When it does, we can make the default stable.
    default = nightly;
  }
