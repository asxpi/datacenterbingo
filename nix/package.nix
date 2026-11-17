# The app with its gems (bundlerEnv, from Gemfile.lock and gemset.nix;
# after changing Gemfile.lock run `nix run nixpkgs#bundix` to refresh
# gemset.nix). bin/datacenterbingo is Puma serving config.ru; pass -b and
# -t like to puma.
{
  lib,
  stdenvNoCC,
  bundlerEnv,
  makeWrapper,
  ruby_4_0,
  version,
}:
let
  root = ../.;
  gems = bundlerEnv {
    name = "datacenterbingo-gems";
    ruby = ruby_4_0;
    gemfile = root + "/Gemfile";
    lockfile = root + "/Gemfile.lock";
    gemset = root + "/gemset.nix";
    groups = [ "default" ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "datacenterbingo";
  inherit version;
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      ../app.rb
      ../config.ru
      ../lib
      ../views
      ../assets
    ];
  };
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    mkdir -p $out/share $out/bin
    cp -r . $out/share/datacenterbingo
    # The lock lists precompiled pg/ffi/prism for many platforms; Nix
    # builds the source gems, so Bundler must not look for the others
    makeWrapper ${gems}/bin/puma $out/bin/datacenterbingo \
      --chdir $out/share/datacenterbingo \
      --set-default RACK_ENV production \
      --set BUNDLE_FORCE_RUBY_PLATFORM true \
      --add-flags "--preload $out/share/datacenterbingo/config.ru"
  '';
  passthru = { inherit gems; };
  meta.mainProgram = "datacenterbingo";
}
