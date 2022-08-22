{
  description = "A hello world unikernel";

  inputs.opam-nix.url = "github:tweag/opam-nix";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  inputs.nix-filter.url =
    "github:numtide/nix-filter/3e1fff9ec0112fe5ec61ea7cc6d37c1720d865f8";
    
  outputs = { self, nixpkgs, nix-filter, opam-nix, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (opam-nix.lib.${system})
          buildOpamProject' queryToScope opamRepository;
      in {
        legacyPackages = let

          # Stage 1: run `mirage configure` on the sources to get mirage/hello-unix.opam
          configure-scope = queryToScope { } { mirage = null; };
          configureSrcFor = target:
            with configure-scope;
            pkgs.stdenv.mkDerivation {
              name = "configured-src";
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
              buildInputs = [ mirage ];
              nativeBuildInputs = [ dune ocaml ];
              phases =
                [ "unpackPhase" "configurePhase" "installPhase" "fixupPhase" ];
              configurePhase = ''
                mirage configure -t ${target}
                # Rename the opam file for package name consistency
                mv mirage/hello-${target}.opam mirage/hello.opam
              '';
              installPhase = "cp -R . $out";
            };

          # Stage 2: read all the opam files from the configured source, and build the hello-unix package
          mkScope = src:
            let
              scope = buildOpamProject' {
                recursive = true;
                resolveArgs.env.monorepo = 1;
              } src { conf-libseccomp = null; };
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
              cp -Lr --no-preserve=ownership ${final.ocaml-solo5}/solo5-sysroot $out
              chmod +rw $out
              cp -Lr ${final.ocaml-solo5}/nix-support $out
            ''; 
            
            hello = prev.hello.override { ocaml = final.ocaml-solo5-sysroot; };
          };

        in {
          unix = mkScope (configureSrcFor "unix");
          virtio =
            (mkScope (configureSrcFor "virtio")).overrideScope' virtio-overlay;
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
