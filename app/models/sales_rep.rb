# 영업 직원·오피서 계정 (F10 — PRD 7장 F10·22장 REF).
# 역할 체계는 단일 테이블 + role 컬럼으로 구분한다(sales/officer — 계정·코드·대시보드 동일 체계).
# - role·status는 Rails enum이 아닌 string 포함 검증(01_plan §2 시그니처 고정 — REF-003 role 정책).
# - commission_rate·commission_cap_months는 컬럼 nil이면 role 기본값
#   (sales 20%·12개월 캡 / officer 15%·무기한) — effective_* 메서드 단일 경유.
# - REF-007: suspend!(reason)는 사유 필수(ADM-001) + 유효 코드 즉시 무효화(replaced_at)·로그인 차단.
# - 로그인 5회 실패 잠금은 AdminUser와 동일 규약(Sales::SessionsController 경유).
class SalesRep < ApplicationRecord
  ROLES = %w[sales officer].freeze
  STATUS_ACTIVE = "active"
  STATUS_SUSPENDED = "suspended"
  STATUSES = [ STATUS_ACTIVE, STATUS_SUSPENDED ].freeze

  # role 기본 수수료율·캡(관리자가 0.05~0.30 범위로 개별 조정 가능 — A2 확장)
  ROLE_DEFAULT_RATES = { "sales" => BigDecimal("0.20"), "officer" => BigDecimal("0.15") }.freeze
  ROLE_DEFAULT_CAP_MONTHS = { "sales" => 12, "officer" => nil }.freeze
  RATE_RANGE = (0.05..0.30).freeze

  MAX_FAILED_ATTEMPTS = 5

  has_secure_password

  # W-4: 금전 이력(REF-004 append-only)·코드 이력(REF-001 보존)은 rep 삭제 시 전량 삭제 금지 —
  # restrict_with_exception으로 콘솔 실수 삭제를 차단(정지(suspend!)가 유일한 생명주기 조치).
  has_many :referral_codes, dependent: :restrict_with_exception
  has_many :commission_ledgers, dependent: :restrict_with_exception
  # 피판매 테넌트 — tenants 삭제가 직원 계정 삭제를 유발하지 않도록 역방향은 Tenant 측 optional.
  has_many :referred_tenants, class_name: "Tenant", foreign_key: :referred_by_sales_rep_id,
                              inverse_of: :referred_by_sales_rep

  validates :name, presence: true
  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: :invalid_email }
  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :commission_rate, numericality: { greater_than_or_equal_to: RATE_RANGE.min,
                                              less_than_or_equal_to: RATE_RANGE.max },
                              allow_nil: true
  validates :commission_cap_months, numericality: { only_integer: true,
                                                    greater_than_or_equal_to: 0 },
                                    allow_nil: true
  validates :password, length: { minimum: 8 }, allow_nil: true
  validate :reason_required_when_suspended # REF-007·ADM-001 2차 방어

  before_validation :normalize_email

  scope :active, -> { where(status: STATUS_ACTIVE) }
  scope :suspended, -> { where(status: STATUS_SUSPENDED) }

  def active?
    status == STATUS_ACTIVE
  end

  def suspended?
    status == STATUS_SUSPENDED
  end

  def sales_role?
    role == "sales"
  end

  # 현재 유효 코드 1개(직원당 유효 1개 불변 — Referral::CodeService가 강제) — REF-001
  def active_referral_code
    referral_codes.live.order(:expires_at, :id).last
  end

  # 결제 시점 수수료율 — 컬럼 nil이면 role 기본(REF-003/004 스냅샷 원천)
  def effective_commission_rate
    commission_rate.presence || ROLE_DEFAULT_RATES.fetch(role)
  end

  # 캡 개월 수 — nil이면 role 기본(officer는 nil=무기한). 무기한 판정은 nil 그대로 사용.
  def effective_cap_months
    return ROLE_DEFAULT_CAP_MONTHS.fetch(role) if commission_cap_months.nil?

    commission_cap_months
  end

  # REF-007: 정지 — 사유 필수 + 유효 코드 즉시 무효화(만료 코드는 이력 보존 — 삭제 금지).
  # 로그인 차단은 suspended? 판정(Sales::SessionsController)과 병행.
  def suspend!(reason)
    raise ArgumentError, "정지 사유는 필수입니다(ADM-001)" if reason.to_s.strip.blank?

    transaction do
      update!(status: STATUS_SUSPENDED, suspended_reason: reason.to_s.strip)
      referral_codes.live.update_all(replaced_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def resume!
    update!(status: STATUS_ACTIVE, suspended_reason: nil)
  end

  # ── 로그인 실패 잠금(5회 — AdminUser 동일 규약) ──
  def locked?
    locked_at.present?
  end

  def register_failed_attempt!
    return false if locked?

    increment(:failed_attempts)
    self.locked_at = Time.current if failed_attempts >= MAX_FAILED_ATTEMPTS
    save!
    locked?
  end

  def reset_failed_attempts!
    return if failed_attempts.zero? && locked_at.nil?

    update!(failed_attempts: 0, locked_at: nil)
  end

  private

  def reason_required_when_suspended
    return unless status == STATUS_SUSPENDED
    return if suspended_reason.present?

    errors.add(:suspended_reason, :blank)
  end

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end
end
