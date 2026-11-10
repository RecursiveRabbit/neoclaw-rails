require "test_helper"

class CredentialReconcilerTest < ActiveSupport::TestCase
  def setup
    CredentialCheckout.delete_all
    @tmp = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def row(instance, boot, scope: "ssh-key")
    dir = File.join(@tmp, instance)
    FileUtils.mkdir_p(dir)
    CredentialCheckout.issue!(scope: scope, instance_name: instance,
                              revoke_handle: "file:#{dir}",
                              launch_ref: "#{boot}:#{instance}")
  end

  test "revokes rows from a previous boot whose pod is gone" do
    stale = row("gone", "oldboot")

    CredentialReconciler.stub(:podman_inventory, []) do
      counts = CredentialReconciler.reconcile!
      assert_equal 1, counts[:revoked]
    end
    refute_nil stale.reload.revoked_at
    assert_equal "boot-reconcile", stale.revoked_reason
  end

  test "keeps rows from the current boot" do
    current = row("fresh", Surface.boot_id)

    CredentialReconciler.stub(:podman_inventory, []) do
      counts = CredentialReconciler.reconcile!
      assert_equal 0, counts[:revoked]
    end
    assert_nil current.reload.revoked_at
  end

  test "keeps rows whose pod is alive even from an older boot" do
    alive = row("running", "oldboot")

    CredentialReconciler.stub(:podman_inventory, [{ name: "running" }]) do
      counts = CredentialReconciler.reconcile!
      assert_equal 1, counts[:kept_live]
      assert_equal 0, counts[:revoked]
    end
    assert_nil alive.reload.revoked_at
  end
end
