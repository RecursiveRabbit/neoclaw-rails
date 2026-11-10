require "test_helper"

class CredentialRevokerTest < ActiveSupport::TestCase
  # Minimal stand-in for HTTPX: one canned response, records calls.
  class FakeHTTP
    attr_reader :calls
    Response = Struct.new(:status)

    def initialize(status)
      @status = status
      @calls = []
    end

    def delete(url, **_opts)
      @calls << url
      Response.new(@status)
    end
  end

  def setup
    CredentialCheckout.delete_all
    @tmp = Dir.mktmpdir
    # Surface.forgejo_admin_token fetches from ENV with no default on purpose
    # (no token in the repo); the suite supplies a fake one.
    @old_token = ENV["FORGEJO_ADMIN_TOKEN"]
    ENV["FORGEJO_ADMIN_TOKEN"] = "test-token"
  end

  def teardown
    CredentialRevoker.http_override = nil
    ENV["FORGEJO_ADMIN_TOKEN"] = @old_token
    FileUtils.rm_rf(@tmp)
  end

  def with_http(fake)
    CredentialRevoker.http_override = fake
    yield
  ensure
    CredentialRevoker.http_override = nil
  end

  test "revokes a forgejo user and closes its row" do
    row = CredentialCheckout.issue!(scope: "forgejo-user", instance_name: "alpha",
                                    revoke_handle: "forgejo:user:alpha",
                                    launch_ref: "boot1:alpha")
    fake = FakeHTTP.new(204)

    with_http(fake) do
      assert_equal :revoked, CredentialRevoker.revoke(row, reason: "teardown")
    end

    row.reload
    refute_nil row.revoked_at
    assert_equal "teardown", row.revoked_reason
    assert_includes fake.calls.first, "/api/v1/admin/users/alpha"
  end

  test "a 404 counts as already revoked; a 500 does not" do
    gone = CredentialCheckout.issue!(scope: "forgejo-user", instance_name: "beta",
                                     revoke_handle: "forgejo:user:beta", launch_ref: "b:beta")
    broken = CredentialCheckout.issue!(scope: "forgejo-user", instance_name: "gamma",
                                       revoke_handle: "forgejo:user:gamma", launch_ref: "b:gamma")

    with_http(FakeHTTP.new(404)) do
      assert_equal :revoked, CredentialRevoker.revoke(gone, reason: "teardown")
    end
    with_http(FakeHTTP.new(500)) do
      assert_equal :failed, CredentialRevoker.revoke(broken, reason: "teardown")
    end

    refute_nil gone.reload.revoked_at
    assert_nil broken.reload.revoked_at
    assert_match(/HTTP 500/, broken.note)
  end

  test "file handles remove the real directory" do
    keydir = File.join(@tmp, "alpha")
    FileUtils.mkdir_p(keydir)
    File.write(File.join(keydir, "authorized_keys"), "ssh-ed25519 AAAA\n")

    row = CredentialCheckout.issue!(scope: "ssh-key", instance_name: "alpha",
                                    revoke_handle: "file:#{keydir}", launch_ref: "b:alpha")

    assert_equal :revoked, CredentialRevoker.revoke(row, reason: "teardown")
    refute Dir.exist?(keydir)
    refute_nil row.reload.revoked_at
  end

  test "unrevocable rows stay open and are reported as such" do
    row = CredentialCheckout.issue!(scope: "generic-token", instance_name: "delta",
                                    revoke_handle: "generic:/api/v1/tokens",
                                    launch_ref: "b:delta", unrevocable: true)

    counts = CredentialRevoker.revoke_all("delta", reason: "teardown")
    assert_equal 1, counts[:unrevocable]
    assert_equal 0, counts[:revoked]
    assert_nil row.reload.revoked_at
  end

  test "an unknown handle kind fails loudly instead of pretending" do
    row = CredentialCheckout.issue!(scope: "generic-token", instance_name: "eps",
                                    revoke_handle: "wat:something", launch_ref: "b:eps")
    assert_equal :failed, CredentialRevoker.revoke(row, reason: "teardown")
    assert_nil row.reload.revoked_at
    assert_match(/no revoker/, row.note)
  end

  test "revoke_all closes every open row for one instance and nothing else" do
    a1 = CredentialCheckout.issue!(scope: "forgejo-user", instance_name: "a", revoke_handle: "file:#{@tmp}/a1", launch_ref: "b:a")
    a2 = CredentialCheckout.issue!(scope: "ssh-key", instance_name: "a", revoke_handle: "file:#{@tmp}/a2", launch_ref: "b:a")
    b1 = CredentialCheckout.issue!(scope: "ssh-key", instance_name: "b", revoke_handle: "file:#{@tmp}/b1", launch_ref: "b:b")
    FileUtils.mkdir_p([a1.revoke_handle.split(":", 2).last, a2.revoke_handle.split(":", 2).last, b1.revoke_handle.split(":", 2).last])

    counts = CredentialRevoker.revoke_all("a", reason: "orphan")
    assert_equal 2, counts[:revoked]
    refute_nil a1.reload.revoked_at
    refute_nil a2.reload.revoked_at
    assert_nil b1.reload.revoked_at
  end
end
