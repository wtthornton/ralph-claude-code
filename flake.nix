{
  description = "Ralph for Claude Code - Autonomous AI development loop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Runtime dependencies required by ralph
        runtimeDeps = with pkgs; [
          bash
          jq
          git
          nodejs_18
          tmux
          coreutils
          gnugrep
          gnused
          curl
        ];

        ralph = pkgs.stdenv.mkDerivation {
          pname = "ralph-claude-code";
          version =
            let
              packageJson = builtins.fromJSON (builtins.readFile ./package.json);
            in
            packageJson.version;

          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # No build step needed - ralph is a bash project
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            # Create directories
            mkdir -p $out/share/ralph
            mkdir -p $out/bin

            # Copy all project files
            cp -r . $out/share/ralph/

            # Make scripts executable
            chmod +x $out/share/ralph/ralph_loop.sh
            chmod +x $out/share/ralph/ralph_monitor.sh
            chmod +x $out/share/ralph/ralph_enable.sh
            chmod +x $out/share/ralph/ralph_enable_ci.sh
            chmod +x $out/share/ralph/ralph_import.sh
            chmod +x $out/share/ralph/setup.sh
            chmod +x $out/share/ralph/install.sh
            chmod -R +x $out/share/ralph/lib/ 2>/dev/null || true

            # Create wrapper scripts with runtime deps on PATH
            makeWrapper $out/share/ralph/ralph_loop.sh $out/bin/ralph \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            makeWrapper $out/share/ralph/ralph_monitor.sh $out/bin/ralph-monitor \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            makeWrapper $out/share/ralph/ralph_enable.sh $out/bin/ralph-enable \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            makeWrapper $out/share/ralph/ralph_enable_ci.sh $out/bin/ralph-enable-ci \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            makeWrapper $out/share/ralph/ralph_import.sh $out/bin/ralph-import \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            makeWrapper $out/share/ralph/setup.sh $out/bin/ralph-setup \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Autonomous AI development loop with intelligent exit detection and rate limiting";
            homepage = "https://github.com/frankbria/ralph-claude-code";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "ralph";
          };
        };

      in
      {
        packages = {
          default = ralph;
          ralph = ralph;
        };

        # nix develop - development shell with all dependencies
        devShells.default = pkgs.mkShell {
          name = "ralph-dev";
          buildInputs = runtimeDeps ++ (with pkgs; [
            # Additional dev dependencies
            bats
            shellcheck
            python312
          ]);

          shellHook = ''
            echo "Ralph for Claude Code - Development Shell"
            echo "  ralph_loop.sh is at: $(pwd)/ralph_loop.sh"
            echo "  Run tests:    npm test"
            echo "  Lint:         shellcheck ralph_loop.sh lib/*.sh"
            echo ""
          '';
        };

        # nix run - run ralph directly
        apps.default = {
          type = "app";
          program = "${ralph}/bin/ralph";
        };
      }
    );
}
