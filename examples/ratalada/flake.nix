{
  description = "async-caldav example server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        name = "caldav";

        pkgs = nixpkgs.legacyPackages.${system};

        gems = pkgs.bundlerEnv {
          name = name;
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = ./gemset.nix;
        };

        server = pkgs.writeShellApplication {
          name = name;
          runtimeInputs = [ gems.wrappedRuby pkgs.coreutils ];
          text = ''
            # Calendars and contacts are the state -- default it somewhere
            # persistent rather than under the store path.
            export CALDAV_DATA_DIR="''${CALDAV_DATA_DIR:-$PWD/data}"
            mkdir -p "$CALDAV_DATA_DIR"
            exec ${gems.wrappedRuby}/bin/ruby ${./server.rb} "$@"
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            gems
            gems.wrappedRuby
            bundix
            libyaml
            openssl
          ];
        };

        packages.default = server;

        apps.default = {
          type = "app";
          program = "${server}/bin/${name}";
        };
      }
    );
}
