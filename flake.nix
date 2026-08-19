{
  description = "async-caldav";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        name = "async-caldav";

        pkgs = nixpkgs.legacyPackages.${system};

        # The gems come from the store, resolved from the checked-in
        # Gemfile.lock and gemset.nix. `.envrc` runs `bundix -l` on entry, so
        # gemset.nix follows the lockfile without a separate step.
        gems = pkgs.bundlerEnv {
          name = name;
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = ./gemset.nix;
          groups = [ "default" "development" ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            gems
            gems.wrappedRuby
            bundix
            libyaml # psych
            openssl # openssl gem
            ripgrep # scampi finds `__END__` spec sections with `rg`
            lefthook # `lefthook install` writes .git/hooks
            trufflehog # what the pre-commit hook scans with
            curl # bin/integration
          ];
        };
      }
    );
}
