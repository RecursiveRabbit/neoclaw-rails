class SheetsController < ApplicationController
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
    RouterConfig.write!
    redirect_to edit_sheet_path(sheet.slug),
                notice: "sheet #{sheet.slug} written; router.conf re-rendered whole"
  rescue Cove::DocumentError => e
    RouterConfig.write!
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
    RouterConfig.write!
    redirect_to edit_sheet_path(sheet.slug),
                notice: "sheet #{sheet.slug} saved; router.conf re-rendered whole"
  rescue Cove::DocumentError => e
    redirect_to sheets_path, alert: "sheet not saved: #{e.message}"
  end

  # The button.
  def start
    sheet = Sheet.find(params[:slug]) or return redirect_to(sheets_path, alert: "no sheet #{params[:slug]}")
    result = Podman.start(sheet)
    # Rendering again here is deliberate: it costs nothing, it is idempotent,
    # and it means no change to the fleet can ever leave the file behind the
    # intent, however the change arrived.
    RouterConfig.write!

    if result.ok?
      redirect_to pod_path(sheet.slug),
                  notice: "podman started #{sheet.pod_name}: #{result.stdout.strip[0, 120]}"
    else
      # No record is written for a failure: the failure IS podman's answer, and
      # it is shown as it came. Nothing in this build marks a pod "failed".
      redirect_to edit_sheet_path(sheet.slug),
                  alert: "podman refused #{sheet.pod_name}: #{result.message[0, 400]}"
    end
  end
end
