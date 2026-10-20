class Guardian < ApplicationRecord
  belongs_to :student

  encrypts :phone_number

  validates :name, presence: true
  validates :phone_number, presence: true,
                           format: { with: /\A01[016789]\d{7,8}\z/, message: :invalid_phone }

  before_validation :normalize_and_set_last4

  private

  def normalize_and_set_last4
    self.phone_number = normalize_phone_number(phone_number)
    self.phone_last4 = phone_number.last(4) if phone_number.present?
  end
end
