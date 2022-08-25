{
  description = "A hello world unikernel";

  inputs.opam-nix.url = "github:tweag/opam-nix";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  # beta so pin commit
  inputs.nix-filter.url = "github:numtide/nix-filter/3e1fff9";
    
  outputs = { self, nixpkgs, nix-filter, opam-nix, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (opam-nix.lib.${system})
          buildOpamProject' queryToScope opamRepository;
      in {
        legacyPackages = let

          # Stage 1: run `mirage configure` on source
          # with mirage, dune, and ocaml from `opam-nix`
          configureSrcFor = target:
            let configure-scope = queryToScope { } { mirage = null; }; in
            pkgs.stdenv.mkDerivation {
              name = "configured-src";
              # only copy these files
              # means only rebuilds when these files change
              src = with nix-filter.lib;
                filter {
                  root = self;
                  include = [
                    (inDirectory "data")
                    (inDirectory "mirage")
                    "config.ml"
                    "dune"
                    "dune-project"
                    "dune.config"
                    "unikernel.ml"
                  ];
                };
              buildInputs = with configure-scope; [ mirage ];
              nativeBuildInputs = with configure-scope; [ dune ocaml ];
              phases = [ "unpackPhase" "configurePhase" "installPhase" "fixupPhase" ];
              configurePhase = ''
                mirage configure -t ${target}
                # Rename the opam file for package name consistency
                # And move to root so a recursive search for opam files isn't required
                mv mirage/hello-${target}.opam hello.opam
              '';
              installPhase = "cp -R . $out";
            };

          # Stage 2: read all the opam files from the configured source, and build the hello package
          mkScope = src:
            let
              scope = buildOpamProject'
                { resolveArgs.env.monorepo = 1; } src { conf-libseccomp = null; };
              overlay = final: prev: {
                hello = (prev.hello.override {
                  # Gets opam-nix to pick up dependencies marked with {?monorepo}
                  extraVars.monorepo = true;
                }).overrideAttrs (_: { inherit src; });
              };
            in scope.overrideScope' overlay;

          virtio-overlay = final: prev: {
            ocaml-solo5-sysroot = pkgs.runCommand "ocaml-solo5-sysroot" {
                version = prev.ocaml.version;
              } ''
                # patch ocaml-solo5 to fix https://github.com/mirage/ocaml-solo5/issues/121
                cp -Lr --no-preserve=ownership ${final.ocaml-solo5}/solo5-sysroot $out
                chmod +rw $out
                cp -Lr ${final.ocaml-solo5}/nix-support $out
              ''; 
            hello = prev.hello.override { ocaml = final.ocaml-solo5-sysroot; };
          };

        in {
          unix = mkScope (configureSrcFor "unix");
          virtio = (mkScope (configureSrcFor "virtio")).overrideScope' virtio-overlay;
        };

        defaultPackage = self.legacyPackages.${system}.unix.hello;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            gcc
            bintools-unwrapped
            gmp
          ];
        };
      });
}
