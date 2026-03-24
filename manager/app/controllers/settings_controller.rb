class SettingsController < AdminController
  def index
    @groups = Setting::DEFAULTS.group_by { |_k, v| v[:group] }
  end

  def update
    changed = []

    params[:settings]&.each do |key, value|
      next unless Setting::DEFAULTS.key?(key)
      old_value = Setting.get(key)
      next if value.to_s.strip == old_value.to_s.strip

      Setting.set(key, value.strip)
      changed << key
    end

    if changed.any?
      AuditLog.record("SETTINGS_UPDATE", detail: "Changed: #{changed.join(', ')}")
    end

    redirect_to settings_path,
      notice: changed.any? ? "#{changed.size} setting(s) updated." : "No changes."
  end
end
