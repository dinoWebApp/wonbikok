class Tenant < ApplicationRecord
  enum :business_type, {
    academy: "교습소",
    study_room: "공부방",
    arts_pe: "예술·체육 교습소"
  }, prefix: true

  # 현금영수증 연동 상태 (W1: pending 고정, 실연동은 W3 F5)
  enum :cash_receipt_link_status, {
    pending: "pending",
    linked: "linked",
    failed: "failed"
  }, prefix: :cash_receipt

  has_many :users, dependent: :destroy
  has_many :students, dependent: :destroy

  validates :name, presence: true
  validates :business_number, format: { with: /\A\d{10}\z/, message: :invalid_business_number },
                              allow_nil: true

  # 온보딩 2스텝(사업자 정보) 서버측 완결성(WARNING-1) — 가입(1스텝)에는 적용되지 않음
  validates :name, :business_number, :business_type, :owner_name, presence: true, on: :business_info

  before_validation :normalize_business_number

  # 온보딩 마법사: 1=가입, 2=사업자 정보, 3=납부 계좌, 4=연동 안내, 5=연습 모드, 6=완료
  ONBOARDING_FINAL_STEP = 6

  def onboarding_complete?
    onboarding_step >= ONBOARDING_FINAL_STEP
  end

  private

  def normalize_business_number
    self.business_number = normalize_phone_number(business_number) if business_number.present?
  end
end
