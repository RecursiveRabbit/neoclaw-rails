module Cove
  class PodsController < ApplicationController
    # The suite drives this one; see the note on SheetsController's forgery skip.
    skip_forgery_protection only: %i[destroy_all]
    def index
      @sheets = Sheet.all.index_by(&:slug)
      @error = nil
      begin
        @pods = Podman.managed
      rescue Cove::DocumentError => e
        @pods = []
        @error = e.message
      end
      # Pods the world knows about that no sheet claims. Not an error: it is what
      # a sheet deleted while its pod ran looks like, and the UI says so.
      @orphans = @pods.reject { |p| @sheets.key?(agent_label(p)) }
    end

    def show
      @sheet = Sheet.find(params[:slug])
      @pod_name = "cove-#{params[:slug]}"
      @error = nil
      begin
        @pods = Podman.managed
      rescue Cove::DocumentError => e
        @pods = []
        @error = e.message
      end
      @pod = @pods.find { |p| agent_label(p) == params[:slug] || container_name(p) == @pod_name }
      # Facts, asked now, from the relay, one question at a time. Each answer or
      # refusal is shown with its own reason.
      @facts = Relay.panel(params[:slug])
    end

    def stop
      name = "cove-#{params[:slug]}"
      result = Podman.stop(name)
      RouterConfig.write!(Plan.network_map)
      if result.ok?
        redirect_to pods_path, notice: "podman stopped #{name}"
      else
        redirect_to pod_path(params[:slug]), alert: "podman could not stop #{name}: #{result.message[0, 400]}"
      end
    end

    # Evans' teardown row: every pod this Manager launched, gone, and nothing left
    # standing on the Router. The answer is a redirect, because the page the caller
    # should look at is the pod list — which is a query against the world, made after
    # the fact, and therefore the only honest witness that the pods are gone.
    def destroy_all
      result = Launch.destroy_all!
      if result.ok?
        redirect_to pods_path, notice: result.message
      else
        redirect_to pods_path, alert: "teardown incomplete: #{result.message[0, 600]}"
      end
    end

    private

    # Podman's JSON shape differs between filters and inspect; read it defensively
    # and by label first, because the label is ours and the field names are not.
    def agent_label(pod)
      labels = pod["Labels"] || pod["labels"] || {}
      labels.is_a?(Hash) ? labels["cove.agent"].to_s : ""
    end

    def container_name(pod)
      names = pod["Names"] || pod["names"] || pod["Name"] || pod["name"]
      case names
      when Array then names.first.to_s
      when String then names.to_s
      else ""
      end
    end
    helper_method :agent_label, :container_name
  end
end
