class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  private

  def normalize_phone_number(value)
    value.to_s.gsub(/[^0-9]/, "")
  end
end
