{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "tabctl";
  version = "2.3.1";

  src = fetchFromGitHub {
    owner = "slastra";
    repo = "tabctl";
    tag = "v${finalAttrs.version}";
    hash = "sha256-n5JASFzF3mnGAGSgxLKXmGSGuh29fK57UjdJK1DSTPE=";
  };

  vendorHash = "sha256-58hQdEBq+LZAs9JwV6UFy1QftTn8r9qhXGfDTfKnm1o=";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/tabctl/tabctl/internal/config.Version=${finalAttrs.version}"
  ];

  # What `tabctl install` writes for Firefox (internal/cli/install_helper.go).
  postInstall = ''
    mkdir -p $out/lib/mozilla/native-messaging-hosts
    cat > $out/lib/mozilla/native-messaging-hosts/tabctl_mediator.json <<EOF
    {
      "name": "tabctl_mediator",
      "description": "TabCtl native messaging host",
      "path": "$out/bin/tabctl-mediator",
      "type": "stdio",
      "allowed_extensions": [
        "tabctl@slastra.github.io"
      ]
    }
    EOF
  '';

  meta = {
    description = "Control browser tabs from the command line and D-Bus";
    homepage = "https://github.com/slastra/tabctl";
    license = lib.licenses.mit;
    mainProgram = "tabctl";
    platforms = lib.platforms.linux;
  };
})
