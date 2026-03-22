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

    if event_type == "m.room.name"
      name = event.dig("content", "name")
      if name && room_id
        Hub::Rooms.update_name(room_id, name)
        Rails.logger.info "learned room name #{room_id} -> #{name}"
      end
      return
    end

    if event_type == "m.room.canonical_alias"
      alias_str = event.dig("content", "alias")
      if alias_str && room_id
        Hub::Rooms.update_alias(room_id, alias_str)
        Rails.logger.info "learned room alias #{room_id} -> #{alias_str}"
      end
      return
    end

    # Agent invited to a room — accept immediately. When a message
    # arrives later, the puppet is already in the room and state
    # queries just work.
    if event_type == "m.room.member"
      membership = event.dig("content", "membership")
      state_key = event["state_key"] || ""
      if membership == "invite" && room_id
        name = state_key.split(":").first&.delete_prefix("@")
        if name && Hub::Identities.exists?(name)
          Hub::Matrix.join_room(state_key, room_id)
          Rails.logger.info "#{name} accepted invite to #{room_id}"
        end
      end
      return
    end

    return unless event_type == "m.room.message"
    return unless room_id

    room = Hub::Rooms.get(room_id)

    unless room&.dig(:slug)
      # First time seeing this room. Alias first — that's the slug source.
      canonical_alias = Hub::Matrix.room_alias(room_id)
      if canonical_alias
        Hub::Rooms.update_alias(room_id, canonical_alias)
      end

      # Name is fallback for named rooms without an alias.
      unless canonical_alias
        name = Hub::Matrix.room_name(room_id)
        Hub::Rooms.update_name(room_id, name) if name
      end

      # Still no slug? Check if it's a DM — derive slug from the other member.
      room = Hub::Rooms.find_or_create(room_id)
      unless room[:slug]
        dm_slug = derive_dm_slug(room_id, event)
        if dm_slug
          Hub::Rooms.update_name(room_id, dm_slug)
          room = Hub::Rooms.get(room_id)
        end
      end
    end

    slug = room[:slug]
    unless slug
      Rails.logger.error "Cannot route message in #{room_id} — no slug (no name or alias known)"
      return
    end

    # Extract attachments from media messages (m.image, m.file, etc.)
    attachments = extract_attachments(event)

    Hub::Router.route(event, room_id: room_id, slug: slug, attachments: attachments)
  end

  MEDIA_MSGTYPES = %w[m.image m.file m.audio m.video].to_set.freeze

  def extract_attachments(event)
    content = event["content"] || {}
    msgtype = content["msgtype"]
    return [] unless MEDIA_MSGTYPES.include?(msgtype)

    mxc_url = content["url"]
    return [] unless mxc_url

    media = Hub::Matrix.download_media(mxc_url)
    return [] unless media

    filename = content["body"] || media[:filename]
    [{
      filename: filename,
      content_type: media[:content_type],
      data: Base64.strict_encode64(media[:data]),
      msgtype: msgtype
    }]
  end

  # Derive a DM slug from room membership. Two people in a room = DM.
  # Returns "dm-<other_user>" or nil if not a DM.
  def derive_dm_slug(room_id, _event)
    members = Hub::Matrix.room_members(room_id)
    return nil unless members

    # Filter out appservice bot
    participants = members.reject { |m| m == Hub::Config.appservice_user }
    return nil unless participants.size == 2

    # Find our agent and the other person
    agent = participants.find { |m| Hub::Identities.exists?(m) }
    other = participants.find { |m| m != agent }
    return nil unless agent && other

    "dm-#{other}"
  end
end
