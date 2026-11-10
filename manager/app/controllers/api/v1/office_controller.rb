# GET  /api/v1/office/state
# POST /api/v1/office/agents/:handle/actions
# GET  /api/v1/office/actions/:id
#
# The office UI's only door into the Manager. WireGuard is the authentication:
# the Router admits only the host WG source address to this port; there is no
# token path and no loopback alternative. This controller adds no auth of its
# own and must not, or the boundary would drift into two half-walls.

module Api
  module V1
    class OfficeController < ActionController::API
      before_action :require_json_body, only: [:create_action]

      # GET /api/v1/office/state
      def state
        render json: OfficeState.as_api
      end

      # POST /api/v1/office/agents/:handle/actions  {action:, reason:}
      def create_action
        handle = params[:handle].to_s
        # NB: params[:action] is Rails' own controller-action key — read the
        # caller's `action` from the raw request parameters.
        action_name = request.request_parameters["action"].to_s

        unless OfficeAction::ACTIONS.include?(action_name)
          return render json: { error: "unknown action '#{action_name}'",
                                allowed: OfficeAction::ACTIONS }, status: :unprocessable_entity
        end

        record = OfficeAction.new(
          id: SecureRandom.uuid,
          handle: handle,
          action: action_name,
          reason: params[:reason].to_s.presence,
          state: "pending"
        )

        unless record.save
          return render json: { error: record.errors.full_messages.join("; ") },
                        status: :unprocessable_entity
        end

        # Kick the executor; the caller polls. A 30-second spawn must never be
        # presented as a synchronous success.
        Thread.new do
          OfficeActionRunner.run(record.id)
        rescue => e
          Rails.logger.error "office action thread: #{e.class}: #{e.message}"
        end

        render json: record.as_api, status: :accepted
      end

      # GET /api/v1/office/actions/:id
      def show_action
        record = OfficeAction.find_by(id: params[:id])
        return render json: { error: "no such action" }, status: :not_found unless record

        render json: record.as_api
      end

      private

      def require_json_body
        return if request.content_type.to_s.include?("application/json")
        return unless request.post?

        render json: { error: "application/json required" }, status: :unsupported_media_type
      end
    end
  end
end
