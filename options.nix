{ lib, ... }:
{
  options.nixGLPrefix = lib.mkOption {
    type = lib.types.str;
    default = "nixGL";
    description = ''
      Will be prepended to commands which require working OpenGL.

      This needs to be set to the right nixGL package on non-NixOS systems.
    '';
  };
}
