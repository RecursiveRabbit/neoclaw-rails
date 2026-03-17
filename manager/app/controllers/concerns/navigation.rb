module Navigation
  extend ActiveSupport::Concern

  included do
    helper_method :nav_link_class
  end

  private

  def nav_link_class(name)
    base = "text-sm hover:text-amber-400 transition-colors"
    if name == controller_name
      "#{base} text-amber-500"
    else
      "#{base} text-stone-500"
    end
  end
end
