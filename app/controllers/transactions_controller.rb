# Synapse appservice endpoint.
# PUT /_matrix/app/v1/transactions/:txn_id
#
# Synapse sends batches of events. We process each one through the router.

class TransactionsController < ApplicationController
  before_action :verify_hs_token

  # PUT /_matrix/app/v1/transactions/:txn_id
  def create
    events = params[:events] || []
    events.each { |event| process_event(event) }
    render json: {}
  end

  private

  def verify_hs_token
    token = extract_token
    unless token == Hub::Config.hs_token
      Rails.logger.warn "DENY: invalid hs_token from #{request.remote_ip}"
      render json: { errcode: "M_FORBIDDEN" }, status: :forbidden
    end
  end

  def extract_token
    auth = request.headers["Authorization"]
    if auth&.start_with?("Bearer ")
      auth[7..]
    else
      params[:access_token]
    end
  end

  def process_event(event)
    event_type = event["type"]
    room_id = event["room_id"]

    # Learn room names from state events
    if event_type == "m.room.name"
      name = event.dig("content", "name")
      update_room_name(room_id, name) if name && room_id
      return
    end

    if event_type == "m.room.canonical_alias"
      alias_str = event.dig("content", "alias")
      if alias_str && room_id
        name = alias_str.split(":").first
        update_room_name(room_id, name)
      end
      return
    end

    # Only route message events
    return unless event_type == "m.room.message"
    return unless room_id

    room = Room.find_or_create_by!(matrix_room_id: room_id) do |r|
      r.name = Hub::Matrix.room_name(room_id) || room_id
    end

    Hub::Router.route(event, room: room)
  end

  def update_room_name(room_id, name)
    room = Room.find_or_initialize_by(matrix_room_id: room_id)
    room.name = name
    room.slug = nil  # force re-derive
    room.save!
    Rails.logger.info "learned room #{room_id} -> #{room.slug}"
  end
end
