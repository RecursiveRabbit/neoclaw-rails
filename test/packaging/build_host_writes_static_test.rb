# STATIC — the Containerfiles, read as text. Not a build, not an image.
#
# A build must not mutate the host it runs on. These images do need a WireGuard
# config *inside* them (`COPY wg0.conf /etc/wireguard/wg0.conf`), and that is the
# build's business; what must never appear in a Containerfile is a live change to
# the build host's own WireGuard — `wg set`, or a write to
# `/etc/wireguard/nc-host.conf`.
#
# There IS such a mutation today, and it is why this row exists:
#
#   manager/build.sh:306        wg set nc-host peer "$ROUTER_PUBKEY" ...
#   manager/build.sh:316-327    cat > /etc/wireguard/nc-host.conf ...
#
# That file is both the build and the deploy: running it peaks the host into the
# Router's mesh as root. It is also the only thing that produces the `wg0.conf`
# the Containerfiles COPY, so `podman build` cannot be reproduced without it —
# which is the defect, and it is tracked as its own row rather than fixed here
# (manager/*.sh is not this row's to change).
#
# This row pins the boundary so the defect does not spread into the images: no
# Containerfile may grow a host mutation. It says nothing about whether the
# images build, and it is named static for that reason.

require "test_helper"

class BuildHostWritesStaticTest < ActiveSupport::TestCase
  CONTAINERFILES = %w[
    Containerfile.hub
    manager/Containerfile
    deploy/babo/Containerfile
  ].freeze

  test "static: no Containerfile mutates the build host's WireGuard" do
    CONTAINERFILES.each do |relative|
      path = Rails.root.join(relative)
      assert File.file?(path), "#{relative} is missing"

      text = File.read(path)
      refute_match(/\bwg\s+set\b/, text, "#{relative} runs `wg set` — a build must not change the host's WireGuard")
      refute_match(%r{nc-host}, text, "#{relative} names the host's nc-host peer — that is a deploy, not a build")
    end
  end
end
