require "test_helper"

# An error body from a provisioning service is attacker-adjacent text: the
# service may echo the credential it was handed. These tests hold the rule that
# nothing token-shaped reaches a log through ProvisionError's message.
class ProvisionerErrorExcerptTest < ActiveSupport::TestCase
  Resp = Struct.new(:status, :body)

  def excerpt(body)
    Provisioner.send(:error_excerpt, Resp.new(400, body))
  end

  test "masks the value of a token-shaped key and keeps the reason" do
    out = excerpt('{"error":"bad request","token":"ghp_supersecretvalue"}')
    refute_includes out, "ghp_supersecretvalue"
    assert_includes out, "[redacted]"
    assert_includes out, "bad request"
  end

  test "masks a long opaque run even with no key naming it" do
    out = excerpt("nope: 0123456789abcdef0123456789abcdef")
    refute_includes out, "0123456789abcdef"
    assert_includes out, "[redacted]"
  end

  test "bounds the excerpt" do
    # Short words, so nothing collapses into an opaque-run mask: the bound, not
    # the masking, is what this test is about.
    out = excerpt("ab " * 200)
    assert_operator out.length, :<=, 161
    assert out.end_with?("…"), "a truncated excerpt says so"
  end

  test "an empty body is named, not printed as nothing" do
    assert_equal "(empty body)", excerpt("")
    assert_equal "(empty body)", excerpt(nil)
  end
end
