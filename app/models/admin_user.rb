# 운영 관리자 계정 (PRD 12장 A0 — 1인 운영, 단일 계정).
# A0: 이메일 + 비밀번호 + 2단계 인증(OTP) 필수, 로그인 5회 실패 시 잠금(해제는 콘솔 — 본인 확인 절차).
# 역할 체계(SUPPORT/BILLING_OPS 등)는 운영 인력 확대 시 도입 — role 컬럼으로 확장 가능 설계(A0).
# otp_secret은 사전 공유 시크릿(암호화 저장 아님 — 값 자체가 TOTP 키이므로 화면·로그 노출 금지, ADM-002).
# 미설정 시 Admin::OtpService가 credentials otp_seed에서 파생(개발 폴백 고정값 + 경고 로그).
class AdminUser < ApplicationRecord
  has_secure_password

  MAX_FAILED_ATTEMPTS = 5

  # OTP 검증·시크릿 파생은 Admin::OtpService 단일 경유(컨트롤러·뷰에서 직접 TOTP 계산 금지).
  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: :invalid_email }
  validates :password, length: { minimum: 8 }, allow_nil: true

  before_validation :normalize_email

  scope :locked, -> { where.not(locked_at: nil) }

  def locked?
    locked_at.present?
  end

  # 로그인 5회 실패 잠금(A0) — 실패 기록은 AuditLog(login_failure/account_locked)에서 병행.
  # 이미 잠긴 계정은 실패 카운트를 추가로 올리지 않는다(재시도 무의미 — MSG 재시도 무한반복 금지 정신 준용).
  def register_failed_attempt!
    return false if locked?

    increment(:failed_attempts)
    if failed_attempts >= MAX_FAILED_ATTEMPTS
      self.locked_at = Time.current
    end
    save!
    locked?
  end

  # 로그인 성공(2단계 완료) 시 실패 카운트 리셋.
  def reset_failed_attempts!
    return if failed_attempts.zero? && locked_at.nil?

    update!(failed_attempts: 0, locked_at: nil)
  end

  # 잠금 해제 — 1인 운영: 콘솔에서만 실행(bin/rails runner). UI 해제 경로는 제공하지 않는다(A0).
  def unlock!
    update!(failed_attempts: 0, locked_at: nil)
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end
end
