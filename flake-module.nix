{ uv2nix, pyproject-nix, pyproject-build-systems, ... }@inputs:
{ config, lib, ... }@args: with builtins;
let
  inherit (lib) mkOption types;

  types-record = attrs: types.submodule {
    options =
      mapAttrs
      (name: type:
        if    lib.options.isOption type
        then  type
        else
          if    types.isOptionType type
          then  mkOption { inherit type; }
          else  throw ''
            types-record attr parameter's values must be options
            or option types. attr '${name}' is neither.
          ''
      )
      attrs;
  };

  types-workspace = types-record {
    mkPyprojectOverlay =
      types.functionTo
        (types.functionTo types.attrs);

    mkEditablePyprojectOverlay =
      types.functionTo
        (types.functionTo types.attrs);

    config = types.attrs;

    deps = types-record {

    };
  };
in {
  options.uv2nix = mkOption {
    description = "flake-module options for uv2nix";
    type = types-record {
      workspace = types-record {
        root = types.path;
        name = types.str;

        config = types.attrTag {
          attrs = types.attrs;
          transformer = mkOption {
            description = ''
              A function taking the generated config as an
              argument, and returning the augmented config
            '';
            type = types.functionTo types.attrs;
          };
        };

        pyproject = types-record {
          root = mkOption {
            type = types.str;
            default = "$REPO_ROOT";
          };

          sourcePreference = types.enum [
            "wheel"
            # TODO: more
          ];
        };
      };

      python = mkOption {
        type = types.attrTag {
          package = mkOption {
            description = "The nix package to use for python";
            type = types.package;
          };

          packageName = mkOption {
            description =
              "The nixpkgs package name to use to source python with";
            type = types.str;
          };
        };

        default = { package = pkgs.python3; };
      };
    };
  };

  config =
    let
      cfg = config.uv2nix;

      workspace = uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = cfg.workspace.root;
      };

      overlay = workspace.mkPyprojectOverlay {
        inherit (cfg.workspace.pyproject) sourcePreference;
      };

      mkPythonSetUsing = pkgs:
        let
          python =
            cfg.python.package or (getAttr cfg.python.packageName pkgs);

          pkg = pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          };

          pkg-extensions = lib.composeManyExtensions [
            inputs.pyproject-build-systems.overlays.wheel
            overlay
          ];
        in
          pkg.overrideScope pkg-extensions;

    in rec {
      perSystem = { system, pkgs, ... }:
      let
        pythonSet = mkPythonSetUsing pkgs;
      in {
        packages.uv2nix =
          pythonSet.mkVirtualEnv
            "${cfg.workspace.name}-env"
            workspace.deps.default;

        devShells.uv2nix =
          pkgs.mkShell
            (flake.lib.uv2nix.mkShellArgs {
              inherit pkgs pythonSet;
            });
      };

      flake.lib.uv2nix = {
        inherit mkPythonSetUsing;

        mkShellArgs =
          {
            pkgs,
            pythonSet,

            packages ? [],
            env ? {},
            shellHook ? "",
            ...
          }@args:
          let
            misc-args = removeAttrs args [ "pkgs" "pythonSet" "packages" "env" "shellHook" ];

            editableOverlay = workspace.mkEditablePyprojectOverlay {
              inherit (cfg.workspace.pyproject) root;
            };

            pythonSet' = pythonSet.overrideScope editableOverlay;

            virtualenv =
              pythonSet'.mkVirtualEnv
              "${cfg.workspace.name}-env-dev"
              workspace.deps.all;
          in
            { packages = packages ++ [ virtualenv pkgs.uv ];

              env = {
                UV_NO_SYNC = "1";
                UV_PYTHON = pythonSet'.python.interpreter;
                UV_PYTHON_DOWNLOADS = "never";
              } // env;

              shellHook = ''
                unset PYTHONPATH
                export REPO_ROOT=$(git rev-parse --show-toplevel)
              '' + shellHook;
            } // misc-args;
      };
    };
}
