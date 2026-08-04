# This flake allows a user to run any version of the
# roc nightly compiler as listed in sources.json as
# available on the host platform for the listed systems.
# It provides built-in smoke test via checks, an overlay...
{
  description = "Official Roc new-compiler nightly binaries";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nixos-unstable no longer supports Intel macOS (x86_64-darwin)
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-darwin,
  }: let
    inherit (nixpkgs) lib;

    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];

    # A function which maps each system in systems
    # to the fn provided to it (in this case, the
    # system switching logic).
    eachSystem = lib.genAttrs systems;

    # Map every system to its corresponding nixpkgs package
    # set.
    # e.g.   {
    #      x86_64-linux = nixpkgs.legacyPackages.x86_64-linux;
    #      aarch64-linux = nixpkgs.legacyPackages.aarch64-linux;
    #      x86_64-darwin = nixpkgs-darwin.legacyPackages.x86_64-darwin;
    #      aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin;
    #    }
    pkgsFor = eachSystem (
      system:
        if system == "x86_64-darwin"

        then nixpkgs-darwin.legacyPackages.${system}
        else nixpkgs.legacyPackages.${system}
    );
  in {
    # Call default.nix for every system & pkg for that system,
    # resulting package set is all the pkgs for host platform's
    # system (i.e. the one running this flake).
    #
    # result e.g.:
    # {
    #     x86_64-linux = {
    #     default = <Roc derivation>;
    #     nightly = <Roc derivation>;
    #     "nightly-2026-..." = <Roc derivation>;
    #   };
    #
    #   # Other systems...
    # }
    packages = lib.mapAttrs (system: pkgs: import ./default.nix {inherit pkgs system;}) pkgsFor;

    apps = eachSystem (system: {
      default = self.apps.${system}.roc;
      roc = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/roc";
        meta.description = "Run the latest recorded Roc nightly";
      };
    });

    # Extend a consumer's nixpkgs package set with the
    # packages provided by the overlay.
    overlays.default = final: prev: {
      # Roc package set for the selected platform, e.g.
      # {
      #         default = <derivation>;
      #         nightly = <derivation>;
      #         "nightly-2026-..." = <derivation>;
      # }
      rocpkgs = self.packages.${prev.stdenv.hostPlatform.system};
    };

    formatter =
      lib.mapAttrs (
        _: pkgs:
          pkgs.writeShellScriptBin "roc-overlay-fmt" ''
            exec ${lib.getExe pkgs.alejandra} "$@" .
          ''
      )
      pkgsFor;

    devShells =
      lib.mapAttrs (_: pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            coreutils
            curl
            git
            jq
          ];
        };
      })
      pkgsFor;

    # - Ensures nightly package builds
    # - Checks that roc version exactly matches recorded
    #   metadata from sources.json
    # - Compiles and runs a hello program
    # - Checks its exact stdout
    checks =
      lib.mapAttrs (
        system: pkgs: let
          roc = self.packages.${system}.nightly;
        in {
          nightly = roc;
          smoke = pkgs.runCommand "roc-nightly-smoke" {nativeBuildInputs = [roc];} ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" "$TMPDIR/test"

            test "$(roc version)" = "Roc compiler version ${roc.compilerVersion}"

            cat >"$TMPDIR/test/main.roc" <<'EOF'
            main! = |_args| {
                echo!("Hello from Roc!")
                Ok({})
            }
            EOF

            test "$(cd "$TMPDIR/test" && roc main.roc)" = "Hello from Roc!"
            touch "$out"
          '';
        }
      )
      pkgsFor;
  };
}
