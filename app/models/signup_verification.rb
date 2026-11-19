# 가입 휴대폰 인증 (F10 — REF-006: 가입은 인증 완료 시에만·시도 5회 제한).
# - phone_number는 정규화 숫자만 저장하되 deterministic 암호화(TEN-003 — User#phone_number와 동일).
#   deterministic이므로 번호로 조회 가능(레이트 리밋·검증·소비 모두 번호 조회 경유).
# - 인증번호는 평문 저장 금지 — bcrypt 해시(code_digest)만 저장.
# - 레코드는 재발송 시 폐기(expires_at 경과) 후 새로 생성 — 미소비 레코드 무효화 규약은
#   Signup::PhoneVerificationService 단일 경유.
class SignupVerification < ApplicationRecord
  MAX_ATTEMPTS = 5 # REF-006: 인증 시도 5회 제한
  TTL = 5.minutes
  CODE_LENGTH = 6

  encrypts :phone_number, deterministic: true

  validates :phone_number, presence: true,
                           format: { with: /\A01[016789]\d{7,8}\z/, message: :invalid_phone }
  validates :code_digest, presence: true
  validates :expires_at, presence: true
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :verified, -> { where.not(verified_at: nil) }
  scope :unconsumed, -> { where(consumed_at: nil) }
  scope :consumed, -> { where.not(consumed_at: nil) }

  def verified?
    verified_at.present?
  end

  def consumed?
    consumed_at.present?
  end

  def expired?(at: Time.current)
    expires_at <= at
  end

  def attempts_exhausted?
    attempts >= MAX_ATTEMPTS
  end

  # 검증 대상 레코드 — verified && 미소비 && 미만료(REF-006 가입 서버 검증 조건과 동일 술어).
  # 만료 후 검증 완료 건은 가입에 재사용할 수 없다(만료 코드 가입 거절 — REF-001과 동일 방어선).
  def usable_for_signup?(at: Time.current)
    verified? && !consumed? && !expired?(at:)
  end
end
