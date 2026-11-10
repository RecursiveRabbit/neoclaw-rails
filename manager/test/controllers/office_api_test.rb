require "test_helper"

class OfficeApiTest < ActionDispatch::IntegrationTest
  def setup
    Container.delete_all
    OfficeAction.delete_all
    OfficeState.inventory_override = []
  end

  def teardown
    OfficeState.inventory_override = nil
    OfficeAction.delete_all
  end

  test "GET /api/v1/office/state returns the closed state set and an observed_at" do
    Container.create!(instance_name: "a-one", identity: "a", channel: "general",
                      state: "alive", wg_address: "10.1.0.9")
    OfficeState.inventory_override = [{ name: "a-one", state: "running", ip: "10.1.0.9" }]

    get "/api/v1/office/state"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[alive frozen starting dead unknown], body["states"]
    assert_equal "alive", body["agents"].first["state"]
    assert body["observed_at"]
  end

  test "POST an unknown action is refused with the allowed set" do
    post "/api/v1/office/agents/a-one/actions",
         params: { action: "explode", reason: "test" }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/unknown action/, body["error"])
    assert_equal 0, OfficeAction.count
  end

  test "POST a valid action returns 202 and the action record" do
    post "/api/v1/office/agents/a-one/actions",
         params: { action: "freeze", reason: "operator asked" }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal "pending", body["state"]
    assert_equal "freeze", body["action"]
    assert body["action_id"]

    get "/api/v1/office/actions/#{body['action_id']}"
    assert_response :success
    assert_equal "freeze", JSON.parse(response.body)["action"]
  end

  test "GET an unknown action id is 404, not an empty success" do
    get "/api/v1/office/actions/does-not-exist"
    assert_response :not_found
  end
end
