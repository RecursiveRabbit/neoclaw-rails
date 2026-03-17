require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "returns status" do
    get "/health"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ok", body["status"]
    assert body.key?("hub")
    assert body.key?("manager")
    assert body["hub"].key?("agents_alive")
    assert body["hub"].key?("identities")
    assert body["manager"].key?("containers")
  end
end
