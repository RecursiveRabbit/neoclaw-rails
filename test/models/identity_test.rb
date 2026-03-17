require "test_helper"

class IdentityTest < ActiveSupport::TestCase
  test "name is required" do
    assert_not Identity.new(name: "").valid?
  end

  test "name must be unique" do
    Identity.create!(name: "silas")
    assert_not Identity.new(name: "silas").valid?
  end

  test "instance_name_for regular identity" do
    identity = Identity.new(name: "silas", singleton: false)
    assert_equal "silas-general", identity.instance_name_for("general")
    assert_equal "silas-art", identity.instance_name_for("art")
  end

  test "instance_name_for singleton" do
    identity = Identity.new(name: "hopper", singleton: true)
    assert_equal "hopper", identity.instance_name_for("general")
    assert_equal "hopper", identity.instance_name_for("art")
  end

  test "listens_on? with listener" do
    identity = Identity.create!(name: "hopper", singleton: true)
    identity.listeners.create!(channel_slug: "general")
    assert identity.listens_on?("general")
    assert_not identity.listens_on?("art")
  end
end
