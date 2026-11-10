require "test_helper"

class CredentialCheckoutTest < ActiveSupport::TestCase
  def setup
    CredentialCheckout.delete_all
  end

  test "issues a row with an opaque locator and no secret value" do
    row = CredentialCheckout.issue!(
      scope: "forgejo-user",
      instance_name: "soro-alpha",
      revoke_handle: "forgejo:user:soro-alpha",
      launch_ref: "boot123:soro-alpha"
    )

    assert row.persisted?
    assert_match(/\Aforgejo:user:/, row.revoke_handle)
    refute_nil row.issued_at
    nil == row.revoked_at
    # The table has no secret-bearing column at all: the schema itself is
    # the invariant. If someone adds one, this list must change deliberately.
    assert_equal(
      %w[id scope instance_name launch_ref revoke_handle unrevocable issued_at
         expires_at revoked_at revoked_reason note created_at updated_at].sort,
      CredentialCheckout.column_names.sort
    )
  end

  test "rejects an unknown scope" do
    assert_raises(ActiveRecord::RecordInvalid) do
      CredentialCheckout.issue!(
        scope: "plaintext-password",
        instance_name: "x",
        revoke_handle: "file:/tmp/x"
      )
    end
  end

  test "open_for returns only open rows for that instance" do
    a = CredentialCheckout.issue!(scope: "ssh-key", instance_name: "a", revoke_handle: "file:/tmp/a")
    CredentialCheckout.issue!(scope: "ssh-key", instance_name: "b", revoke_handle: "file:/tmp/b")
    a.revoke!(reason: "teardown")

    assert_equal 0, CredentialCheckout.open_for("a").count
    assert_equal 1, CredentialCheckout.open_for("b").count
  end

  test "unrevocable rows are marked at issue, not at teardown" do
    row = CredentialCheckout.issue!(
      scope: "generic-token", instance_name: "c",
      revoke_handle: "generic:/api/v1/tokens", unrevocable: true,
      note: "no revoke endpoint"
    )
    assert row.unrevocable?
  end
end
