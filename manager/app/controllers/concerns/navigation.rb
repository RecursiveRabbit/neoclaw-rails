module Navigation
  extend ActiveSupport::Concern

  included do
    helper_method :nav_link_class
  end

  private

  def nav_link_class(controller_name)
    base = "text-sm hover:text-amber-400 transition-colors"
    if controller_name == controller.controller_name
      "#{base} text-amber-500"
    else
      "#{base} text-stone-500"
    end
  end
end
