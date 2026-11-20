module Cove
  class SheetsController < ApplicationController
    # Two of these are driven by a machine, not by a browser: the acceptance suite
    # POSTs start and permits, and a machine has no session to carry a token in.
    # The fence here is the bind address (§3, row 1): 127.0.0.1, no LAN, no auth by
    # design. A CSRF check that only a human could satisfy would not protect a
    # control surface this small; it would only make the surface unreachable to the
    # thing that measures it. Forms keep their token.
    skip_forgery_protection only: %i[start permits]
    def index
      @sheets = Sheet.all
      @services = ServiceBook.all
      @router_exists = File.exist?(Cove.router_file)
      @podman_ok = Podman.available?
    rescue Cove::DocumentError => e
      @document_error = e.message
      @sheets = []
      @services = []
    end

    def new
      @sheet = Sheet.new({ "name" => "", "image" => "localhost/cove-agent:latest" })
      @services = ServiceBook.all
    end

    def create
      sheet = Sheet.create!(sheet_attrs)
      # The file is rewritten the moment intent exists, before anything can run.
      RouterConfig.write!(Plan.network_map)
      redirect_to edit_sheet_path(sheet.slug),
                  notice: "sheet #{sheet.slug} written; router.conf re-rendered whole"
    rescue Cove::DocumentError => e
      RouterConfig.write!(Plan.network_map)
      redirect_to sheets_path, alert: "sheet not written: #{e.message}"
    end

    def edit
      @sheet = Sheet.find(params[:slug]) or return redirect_to(sheets_path, alert: "no sheet #{params[:slug]}")
      @services = ServiceBook.all
      @unresolved = @sheet.services - @services.map(&:name)
    end

    def update
      sheet = Sheet.find(params[:slug]) or return redirect_to(sheets_path, alert: "no sheet #{params[:slug]}")
      sheet.assign(sheet_attrs)
      sheet.save!
      RouterConfig.write!(Plan.network_map)
      redirect_to edit_sheet_path(sheet.slug),
                  notice: "sheet #{sheet.slug} saved; router.conf re-rendered whole"
    rescue Cove::DocumentError => e
      redirect_to sheets_path, alert: "sheet not saved: #{e.message}"
    end

    # The button.
    def start
      sheet = Sheet.find(params[:slug]) or return redirect_to(sheets_path, alert: "no sheet #{params[:slug]}")
      result = Launch.ensure!(sheet)

      if result.ok?
        redirect_to pod_path(sheet.slug), notice: "#{result.message}"
      else
        # No record is written for a failure: the failure IS the world's answer, and
        # it is shown as it came. Nothing in this build marks a pod "failed".
        redirect_to edit_sheet_path(sheet.slug), alert: "launch refused: #{result.message[0, 600]}"
      end
    end

    # A permit is not an object. It is a service name on a sheet, and the file the
    # Router reads is the only place a road exists. So setting permits means
    # assigning the list and re-rendering, in that order, and nothing else.
    #
    #   services=service-a service-b     -> those two roads
    #   services=                        -> none (the list is empty, not absent)
    def permits
      sheet = Sheet.find(params[:slug]) or return redirect_to(sheets_path, alert: "no sheet #{params[:slug]}")
      sheet.assign("services" => Sheet.arrayify(params[:services]))
      sheet.save!
      RouterConfig.write!(Plan.network_map)
      redirect_to edit_sheet_path(sheet.slug),
                  notice: "#{sheet.slug} permits: #{sheet.services.empty? ? 'none' : sheet.services.join(' ')}; " \
                          "router.conf re-rendered whole"
    rescue Cove::DocumentError => e
      redirect_to edit_sheet_path(params[:slug]), alert: "permits not set: #{e.message}"
    end
  end
end
