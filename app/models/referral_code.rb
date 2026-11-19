# 추천 코드 (F10 — REF-001: 예측 불가 8자·7일 유효·주간 로테이션).
# 로테이션·정지로 무효화된 코드는 replaced_at으로 이력 보존(만료 코드 삭제 금지) —
# 가입 매핑은 tenants.referral_code_snapshot 스냅샷이므로 과거 코드 행이 남아도 영향 없음.
class ReferralCode < ApplicationRecord
  belongs_to :sales_rep

  validates :code, presence: true, uniqueness: true
  validates :expires_at, presence: true

  # 유효 코드 — 교체(replaced_at) 전 & 만료 전.
  # 가입 검증·직원 대시보드·로테이션 잡이 모두 이 스코프를 단일 경유한다.
  scope :live, -> { where(replaced_at: nil).where(expires_at: Time.current..) }

  def active?
    replaced_at.nil? && expires_at > Time.current
  end
end
