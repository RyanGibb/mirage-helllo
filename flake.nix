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

  inputs.opam-nix-monorepo.url = "github:RyanGibb/opam-nix";
  inputs.opam-nix-monorepo.inputs.nixpkgs.follows = "nixpkgs";
  inputs.opam-nix-monorepo.inputs.flake-utils.follows = "flake-utils";
  inputs.opam-nix-monorepo.inputs.opam-repository.follows = "opam-repository";
  inputs.opam-nix-monorepo.inputs.opam2json.follows = "opam2json";
  inputs.opam-nix-monorepo.inputs.flake-compat.follows = "opam-nix";

  outputs = { self, nixpkgs, flake-utils, opam-nix, opam-nix-monorepo,
      opam2json, nix-filter, opam-repository, opam-overlays, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = nixpkgs.lib;
        inherit (opam-nix.lib.${system}) queryToScope makeOpamRepo;
        opam-nix-monorepo-lib = opam-nix-monorepo.lib.${system};
      in {
        legacyPackages = let

          # run `mirage configure` on source,
          # with mirage, dune, and ocaml from `opam-nix`
          configureSrcFor = target:
            let configure-scope = queryToScope { } { mirage = "*"; }; in
            pkgs.stdenv.mkDerivation {
              name = "configured-src";
              # only copy these files and only rebuild when they change
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

          # collect all dependancy sources in a scope
          mkMonorepoScope = src:
            let
              local-repo = makeOpamRepo src;
              # TODO modify opam-nix with a custom builder to avoid using fork
              scope = opam-nix-monorepo-lib.queryToScope
                {
                  # pass monorepo = 1 to `opam admin list` to pick up dependencies marked with {?monorepo}
                  resolveArgs.env.monorepo = 1;
                  # TODO filter packages not build with dune (or check if this needs to be done)
                  repos = [ local-repo opam-overlays opam-repository ];
                }
                {
                  conf-libseccomp = "*";
                  hello = "*";
                };
              monorepo-overlay = final: prev: {
                hello = prev.hello.override {
                  # Gets opam-nix to pick up dependencies marked with {?monorepo}
                  extraVars.monorepo = true;
                };
              };
            in scope.overrideScope' monorepo-overlay;

          # read all the opam files from the configured source and build the hello package
          mkScope = src:
            let
              local-repo = makeOpamRepo src;
              scope = queryToScope
                { repos = [ local-repo opam-repository ]; }
                { hello = "*"; };
              overlay = final: prev: {
                hello = prev.hello.overrideAttrs (_ :
                  let monorepo-scope = mkMonorepoScope src; in
                  {
                    phases = [ "unpackPhase" "preBuild" "buildPhase" "installPhase" ];
                    preBuild =
                      let
                        ignoredAttrs = [
                          "overrideScope" "overrideScope'" "result" "callPackage" "newScope"
                          "hello" "nixpkgs" "packages" "dune" "ocaml" "mirage"
                          # TODO only pick up dependencies marked with {?monorepo}
                          "functoria" "functoria-runtime" "macaddr" "mirage-clock" "ppx_cstruct" "opam-monorepo"
                        ];
                        scopeFilter = name: builtins.elem "${name}" ignoredAttrs;
                        # TODO get dune build to pick up symlinks
                        createDep = name: path: "cp -r ${path} duniverse/${name}";
                        createDeps = lib.attrsets.mapAttrsToList
                            (name: path: if scopeFilter name then "" else createDep name path)
                            monorepo-scope;
                        createDuniverse = builtins.concatStringsSep "\n" createDeps;
                      in
                    ''
                      # find solo5 toolchain
                      ${if final ? ocaml-solo5 then "export OCAMLFIND_CONF=\"${final.ocaml-solo5}/lib/findlib.conf\"" else ""}
                      # create duniverse
                      mkdir duniverse
                      echo '(vendored_dirs *)' > duniverse/dune
                      ${createDuniverse}
                    '';
                    buildPhase = "dune build";
                    installPhase = "cp -rL ./_build/install/default/bin/ $out";
                  }
                );
              };
            in scope.overrideScope' overlay;

          targets = [ "unix" "virtio" "hvt" ];
          mapTargets = f:
            let mappedTargets = builtins.map (target: lib.attrsets.nameValuePair target (f (configureSrcFor target))) targets; in
            builtins.listToAttrs mappedTargets;
          targetScopes = mapTargets mkScope;
          targetMonorepoScopes = mapTargets mkMonorepoScope;
        in targetScopes  // { monorepo = targetMonorepoScopes ; };

        # need to know package name
        defaultPackage = self.legacyPackages.${system}.unix.hello;
      });
}

