# STATIC — the Containerfile, read as text. Not an image, not a container.
#
# The Manager role inside this image refuses to start unless `podman` is on PATH:
# deploy/babo/entrypoint.sh does `command -v podman` and exits 1 with
#   [babo:manager] FATAL: podman-remote is not installed in the manager
# Debian ships the client as `podman-remote`, so the image needs a symlink. Built
# without it, the image builds cleanly and dies on its first line of work — which
# is exactly what happened on z620 on 2026-11-14, on an image built from #45's
# head, and nothing in this suite would have caught it.
#
# This row reads deploy/babo/Containerfile and asserts the bridge is declared.
# It measures the FILE. It is named static because that is all it is: a source
# assertion is not evidence that any image contains the symlink, and must never
# be reported as one. The container-level claim needs a container.

require "test_helper"

class BaboContainerfileStaticTest < ActiveSupport::TestCase
  CONTAINERFILE = Rails.root.join("deploy/babo/Containerfile")
  ENTRYPOINT = Rails.root.join("deploy/babo/entrypoint.sh")

  test "static: deploy/babo/Containerfile declares the podman bridge its entrypoint requires" do
    assert File.file?(CONTAINERFILE), "#{CONTAINERFILE} is missing"
    containerfile = File.read(CONTAINERFILE)

    # What the entrypoint will demand at run time. Asserted first so the row
    # fails for the right reason if the gate ever changes shape.
    assert File.file?(ENTRYPOINT), "#{ENTRYPOINT} is missing"
    assert_includes File.read(ENTRYPOINT), "command -v podman",
                    "the entrypoint no longer gates on `podman`; revisit this row's premise"

    assert_includes containerfile, "ln -sf /usr/bin/podman-remote /usr/bin/podman",
                    "the Containerfile installs podman-remote but never bridges it to `podman`, " \
                    "so BABO_ROLE=manager exits 1 before it binds anything"
  end
end
