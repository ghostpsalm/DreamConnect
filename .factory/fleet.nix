# DreamConnect: what this repository needs on a Shipyard fleet VM, as a NixOS module.
# Fleet Command (github.com/ghostpsalm/fleet-command) imports this file into
# every host that carries DreamConnect; change it here and Fleet Command picks it up
# on its next input update and deploy. Use only fleet options and nixpkgs:
#   fleet.toolchains.rust.enable / .mingw.enable / .denoLatest.enable,
#   fleet.rust.targets, fleet.pkgConfigLibs, fleet.pythonPackages,
#   fleet.postgres.enable / .package / .setupSQL, fleet.factory.envPassthrough,
#   fleet.factory.gateEnv.<repo> (non-secret gate variables), environment.*
# Never credentials (this lands in the Nix store), never sudo grants.
#
#   gate (run-tests.sh): JDK 21 with javac/jar, unzip, python3 with PyGObject
#   and the GLib/Gio/GStreamer typelibs the daemon imports.
{ lib, pkgs, ... }:
let
  # .out: gstreamer's default output is bin; typelibs and plugins live in out.
  gst = with pkgs.gst_all_1; [ gstreamer.out gst-plugins-base.out ];
in {
  environment.systemPackages = [ pkgs.jdk21 pkgs.unzip ];
  fleet.pythonPackages = [ "pygobject3" ];
  fleet.factory.envPassthrough = [ "GI_TYPELIB_PATH" "GST_PLUGIN_SYSTEM_PATH_1_0" ];
  environment.sessionVariables = {
    GI_TYPELIB_PATH = lib.makeSearchPath "lib/girepository-1.0"
      ([ pkgs.glib.out pkgs.gobject-introspection ] ++ gst);
    GST_PLUGIN_SYSTEM_PATH_1_0 = lib.makeSearchPath "lib/gstreamer-1.0" gst;
  };
}
