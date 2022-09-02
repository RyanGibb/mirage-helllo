{
  description = "A hello world unikernel";

  inputs.nixpkgs.url = "github:nixos/nixpkgs";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-utils.inputs.nixpkgs.follows = "nixpkgs";

  inputs.opam-nix.url = "github:tweag/opam-nix";
  inputs.opam-nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.opam-nix.inputs.flake-utils.follows = "flake-utils";

  inputs.opam2json.url = "github:tweag/opam2json";
  inputs.opam2json.inputs.nixpkgs.follows = "nixpkgs";
  inputs.opam-nix.inputs.opam2json.follows = "opam2json";

  # beta so pin commit
  inputs.nix-filter.url = "github:numtide/nix-filter/3e1fff9";

  inputs.opam-repository = {
    url = "github:ocaml/opam-repository";
    flake = false;
  };
  inputs.opam-nix.inputs.opam-repository.follows = "opam-repository";
  inputs.opam-overlays = {
    url = "github:dune-universe/opam-overlays";
    flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, opam-nix, opam2json, nix-filter, opam-repository, opam-overlays, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (opam-nix.lib.${system}) queryToScope makeOpamRepo;
      in {
        legacyPackages = let

          # Stage 1: run `mirage configure` on source
          # with mirage, dune, and ocaml from `opam-nix`
          configureSrcFor = target:
            let configure-scope = queryToScope { } { mirage = "*"; }; in
            pkgs.stdenv.mkDerivation {
              name = "configured-src";
              # only copy these files
              # means only rebuilds when these files change
              src = with nix-filter.lib;
                filter {
                  root = self;
                  include = [
                    "config.ml"
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
                cp mirage/hello-${target}.opam hello.opam
              '';
              installPhase = "cp -R . $out";
            };

          # Stage 2: read all the opam files from the configured source, and build the hello package
          mkScope = src:
            let
              local-repo = makeOpamRepo src;
              scope = queryToScope
                {
                  # pass monorepo = 1 to `opam admin list` to pick up dependencies marked with {?monorepo}
                  resolveArgs.env.monorepo = 1;
                  repos = [ local-repo opam-repository opam-overlays ];
                }
                {
                  conf-libseccomp = "*";
                  hello = "*";
                };
              overlay = final: prev: {
                hello = (prev.hello.override {
                  # Gets opam-nix to pick up dependencies marked with {?monorepo}
                  extraVars.monorepo = true;
                }).overrideAttrs (_: { inherit src; });
              };
            in scope.overrideScope' overlay;

          virtio-overlay = final: prev: {
            hello = (prev.hello.override { } ).overrideAttrs (_ : {
              preBuild =
                let
                  ignoredAttrs = [
                    "overrideScope" "overrideScope'" "result" "callPackage" "newScope"
                    # need to know name of binary in advance
                    "hello" "nixpkgs" "packages" "dune" "ocaml" "mirage"
                  ];
                  scopeFilter = name: builtins.elem "${name}" ignoredAttrs;
                  createDep = name: path: ''
                    if [ -d ${path}/lib/ocaml/${final.ocaml.version}/site-lib/${name}/ ]; then
                      cp -r ${path}/lib/ocaml/${final.ocaml.version}/site-lib/${name}/ duniverse/${name};
                    fi
                  '';
                  createDeps = nixpkgs.lib.attrsets.mapAttrsToList
                      (name: path: if scopeFilter name then "" else createDep name path)
                      final;
                  createDuniverse = builtins.concatStringsSep "\n" createDeps;
                in
              ''
                # find solo5 toolchain
                export OCAMLFIND_CONF="${final.ocaml-solo5}/lib/findlib.conf"
                # create duniverse
                mkdir duniverse
                echo '(vendored_dirs *)' > duniverse/dune
                ${createDuniverse}
              '';
              phases = [ "unpackPhase" "preBuild" "buildPhase" "installPhase" ];
              buildPhase = ''
                find -L duniverse
                dune build
              '';
              installPhase = ''
                cp -rL ./_build/install/default/bin/ $out
              '';
            });
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

