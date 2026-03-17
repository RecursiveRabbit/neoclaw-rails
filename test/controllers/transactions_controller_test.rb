require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["NEOCLAW_HS_TOKEN"] = "test-hs-token"
    ENV["NEOCLAW_AS_TOKEN"] = "test-as-token"
  end

  test "rejects invalid hs_token" do
    put "/_matrix/app/v1/transactions/1",
      params: { events: [] }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer wrong-token"
      }
    assert_response :forbidden
  end

  test "accepts valid hs_token via header" do
    put "/_matrix/app/v1/transactions/1",
      params: { events: [] }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer test-hs-token"
      }
    assert_response :success
  end

  test "accepts valid hs_token via query param" do
    put "/_matrix/app/v1/transactions/1?access_token=test-hs-token",
      params: { events: [] }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :success
  end

  test "learns room name from state event" do
    put "/_matrix/app/v1/transactions/1?access_token=test-hs-token",
      params: {
        events: [{
          "type" => "m.room.name",
          "room_id" => "!test:localhost",
          "content" => { "name" => "Infrastructure" }
        }]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :success
    room = Room.find_by(matrix_room_id: "!test:localhost")
    assert_not_nil room
    assert_equal "infrastructure", room.slug
  end
end
