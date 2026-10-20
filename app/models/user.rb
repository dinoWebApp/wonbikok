class User < ApplicationRecord
  belongs_to :tenant
  has_many :sessions, dependent: :destroy

  encrypts :phone_number, deterministic: true

  has_secure_password

  enum :role, { owner: "owner", admin: "admin" }, prefix: true

  validates :phone_number, presence: true,
                           uniqueness: true,
                           format: { with: /\A01[016789]\d{7,8}\z/, message: :invalid_phone }
  validates :password, length: { minimum: 8 }, allow_nil: true

  before_validation -> { self.phone_number = normalize_phone_number(phone_number) }
end
