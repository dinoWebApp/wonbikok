class Student < ApplicationRecord
  belongs_to :tenant
  has_many :guardians, dependent: :destroy

  # 대표 보호자 1명 동시 입력(MVP 화면 기준). 복수 보호자 확장은 데이터 모델로 가능.
  accepts_nested_attributes_for :guardians

  # 납부일 허용 범위 — 모델·CSV·폼 단일 기준(WARNING-2, 리마인더 D+3/D+7 기준값)
  PAYMENT_DAY_RANGE = (1..28).freeze

  enum :status, { active: "active", paused: "paused", withdrawn: "withdrawn" }, prefix: true
  enum :payment_type, { bank_transfer: "계좌이체", cash: "현금" }, prefix: true

  validates :name, presence: true
  validates :monthly_fee, numericality: { greater_than_or_equal_to: 0 }
  validates :payment_day, inclusion: { in: PAYMENT_DAY_RANGE }

  before_save :sync_ended_on

  # 청구 대상 기반 스코프 (INV-004: 휴원·퇴원 원생은 청구 생성·발송 대상에서 자동 제외)
  scope :active, -> { where(status: :active) }

  def primary_guardian
    # includes 캐시를 재사용(목록 N+1 방지) — 추가 쿼리 없이 로드된 컬렉션에서 선택
    guardians_all = guardians.to_a
    guardians_all.find(&:is_primary?) || guardians_all.min_by(&:id)
  end

  private

  # 상태 전이 시 종료일 기록·해제(휴원/퇴원 → ended_on 기록, 재원 복원 → 해제)
  def sync_ended_on
    if status_paused? || status_withdrawn?
      self.ended_on ||= Date.current
    else
      self.ended_on = nil
    end
  end
end
