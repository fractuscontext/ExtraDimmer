{
  description = "ExtraDimmer - Software and hardware display dimmer";

  inputs = {
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?shallow=1&ref=nixpkgs-26.05-darwin";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          appName = "ExtraDimmer";
          bundleId = "org.rmuttfurnishings.ExtraDimmer";
          minOS = "14.0";
        in
        rec {
          extradimmer = pkgs.stdenv.mkDerivation {
            pname = "extradimmer";
            version = "1.0.0"; # Keep this base; CI dynamically increments

            src = ./.;

            nativeBuildInputs = [
              pkgs.swift
              pkgs.swiftpm
              pkgs.darwin.sigtool # Supplies ad-hoc codesign capability
            ];

            buildPhase = ''
              # Swap home to fake-home so swiftpm doesn't encounter sandbox violations caching module maps
              export HOME=$(mktemp -d)

              echo "==> Building Swift package (release)"
              swift build -c release --disable-sandbox
            '';

            installPhase = ''
                            BUNDLE_DIR="$out/Applications/${appName}.app"
                            mkdir -p "$BUNDLE_DIR/Contents/MacOS"
                            mkdir -p "$BUNDLE_DIR/Contents/Resources"

                            # Pull directly from swift compiler outputs
                            BIN_PATH=$(swift build -c release --show-bin-path)/${appName}
                            cp "$BIN_PATH" "$BUNDLE_DIR/Contents/MacOS/${appName}"

                            # Link icons over dynamically if exists
                            if [ -f "Assets/AppIcon.icns" ]; then
                              cp "Assets/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
                            fi

                            # Write PList securely using string interpolation
                            cat > "$BUNDLE_DIR/Contents/Info.plist" <<EOF
                            <?xml version="1.0" encoding="UTF-8"?>
                            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                            <plist version="1.0">
                            <dict>
                                <key>CFBundleExecutable</key>
                                <string>${appName}</string>
                                <key>CFBundleIconFile</key>
                                <string>AppIcon</string>
                                <key>CFBundleIdentifier</key>
                                <string>${bundleId}</string>
                                <key>CFBundleName</key>
                                <string>${appName}</string>
                                <key>CFBundleVersion</key>
                                <string>''${version}</string>
                                <key>CFBundleShortVersionString</key>
                                <string>''${version}</string>
                                <key>LSMinimumSystemVersion</key>
                                <string>${minOS}</string>
                                <key>NSHighResolutionCapable</key>
                                <true/>
                                <key>LSUIElement</key>
                                <true/>
                            </dict>
                            </plist>
              EOF

                            # FIXED: Ask sigtool to sign the binary specifically, not the directory bundle
                            codesign --force --sign - "$BUNDLE_DIR/Contents/MacOS/${appName}"
            '';
          };

          meta = with pkgs.lib; {
            description = "Application to make your screen even dimmer";
            homepage = "https://github.com/fractuscontext/ExtraDimmer";
            license = licenses.mit;
            platforms = platforms.darwin;
            mainProgram = "ExtraDimmer";
          };

          # Sets default nix interaction
          default = extradimmer;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          appName = "ExtraDimmer";
          pkg = self.packages.${system}.default; # Fetches the clean nix-build output

          # Wraps dirty host environments like DMG packaging outside the flake environment natively
          makeDmg = pkgs.writeShellScriptBin "make-dmg" ''
            set -euo pipefail
            STAGING_DIR=$(mktemp -d)

            echo "==> Staging DMG contents from pure Nix store..."

            # Rehydrate binary from un-writable Nix Store down to fully writable cache for resigns/changes
            cp -rL "${pkg}/Applications/${appName}.app" "$STAGING_DIR/"
            chmod -R u+w "$STAGING_DIR/${appName}.app"

            # If triggered inside CI, perform version swaps securely using PlistBuddy & resign entirely
            if [ -n "''${NEW_VERSION:-}" ]; then
              echo "==> Triggering Plist Version bump to $NEW_VERSION"
              /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" "$STAGING_DIR/${appName}.app/Contents/Info.plist"
              /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$STAGING_DIR/${appName}.app/Contents/Info.plist"

              echo "==> Resigning Modified Bundle..."
              # FIXED: Explicitly use Apple's Host codesign to prevent local Nix PATH conflicts
              /usr/bin/codesign --force --sign - "$STAGING_DIR/${appName}.app"

              DMG_NAME="${appName}-$NEW_VERSION.dmg"
            else
              DMG_NAME="${appName}.dmg"
            fi

            ln -s /Applications "$STAGING_DIR/Applications"

            echo "==> Rendering final image..."
            rm -f "$DMG_NAME"
            /usr/bin/hdiutil create -volname "${appName}" \
              -srcfolder "$STAGING_DIR" \
              -ov -format UDZO \
              "$DMG_NAME"

            rm -rf "$STAGING_DIR"
            echo "==> Finished compiling: $DMG_NAME"
          '';
        in
        {
          # Generates pure date-formatted version using flake commit timestamp
          print-version = {
            type = "app";
            program = "${pkgs.writeShellScriptBin "print-version" ''
              # Uses GNU standard `date` to format the pure Nix epoch timestamp (self.lastModified)
              ${pkgs.coreutils}/bin/date -u -d @${toString (self.lastModified or 0)} +'%y.%j.%H%M'
            ''}/bin/print-version";
          };

          # CI & Local Trigger
          makeDmg = {
            type = "app";
            program = "${makeDmg}/bin/make-dmg";
          };

          # Allows usage of `nix run` dynamically
          default = {
            type = "app";
            program = "${pkg}/Applications/${appName}.app/Contents/MacOS/${appName}";
          };
        }
      );
    };
}
