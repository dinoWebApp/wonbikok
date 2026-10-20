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
  has_many :invoices, dependent: :destroy
  has_many :message_logs, dependent: :destroy

  # 리마인더 설정(F6) — 문구 톤 3종(부드러움/표준/공식), 단계별 토글, 발송 시각
  REMINDER_TONES = %w[soft standard formal].freeze
  REMINDER_STAGES = %i[d3 d7 month_end].freeze

  # 리마인더 기본 설정(MSG-006: 기본 오전 9시, 야간 발송 금지 — W2 F6 슬라이스가 사용)
  validates :remind_send_hour, inclusion: { in: 9..17, message: :night_send_forbidden }
  validates :remind_tone, inclusion: { in: REMINDER_TONES }

  # 단계별 커스텀 문구(기본 템플릿보다 우선) — d3/d7/month_end
  def remind_custom_text(stage)
    raise ArgumentError, "unknown reminder stage: #{stage}" unless stage.to_s.in?(REMINDER_STAGES.map(&:to_s))

    public_send(:"remind_custom_text_#{stage}")
  end

  validates :name, presence: true
  validates :business_number, format: { with: /\A\d{10}\z/, message: :invalid_business_number },
                              allow_nil: true

  # 온보딩 2스텝(사업자 정보)·3스텝(납부 계좌) 서버측 완결성(W1 후속) — 가입(1스텝)에는 적용되지 않음
  validates :name, :business_number, :business_type, :owner_name, presence: true, on: :business_info
  validates :bank_name, :bank_account, :account_holder, presence: true, on: :bank_info

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
