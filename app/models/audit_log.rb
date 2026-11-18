# 관리자 조치 감사 로그 (PRD 12장 A0·22장 ADM-001 — 영구 보존, 삭제/수정 경로 미제공).
# 기록 대상(A0): 관리자 로그인·인증 실패 / 계정 상태·요금제 변경 / 개인정보 열람·내보내기 /
# 현금영수증 발행·취소·재시도 / 메시지 수동 재발송 / 계정 정지·복구·해지 / 핵심 설정 변경.
#
# ADM-001: 파괴적 조치(정지·환불·플랜 변경·체험 연장 등)는 사유 없이 실행 불가 —
# 사유 필수 강제는 조치 실행 컨트롤러(Admin::TenantActionsController 등)에서 수행하고,
# 본 모델은 "사유 없는 파괴 조치 로그 생성"을 2차 방어로 거절한다(AUDIT_ACTIONS_REQUIRING_REASON).
class AuditLog < ApplicationRecord
  belongs_to :admin_user, optional: true # 로그인 실패 등 계정 미확인 기록 허용

  # 사유가 필수인 파괴적 조치(ADM-001) — 조회성 기록(login/personal_info_viewed 등)은 제외
  AUDIT_ACTIONS_REQUIRING_REASON = %w[
    plan_changed trial_extended tenant_suspended tenant_resumed refund_confirmed
  ].freeze

  # A1 대시보드·A2 타임라인 표시용 최근순
  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :for_target, ->(target) { where(target_type: target.class.name, target_id: target.id) }
  scope :with_reason_required, -> { where(action: AUDIT_ACTIONS_REQUIRING_REASON) }

  validates :action, presence: true
  validate :reason_required_for_destructive_actions # ADM-001 2차 방어

  class << self
    # 통합 기록 진입점 — 조치 컨트롤러는 반드시 이 메서드를 경유한다.
    # detail에는 개인정보 원문을 넣지 않는다(ADM-002 — 식별자·마스킹 값만).
    # created_at은 백데이팅 전용 옵션(테스트·데이터 이관) — 운영 조치 경로에서는 미사용.
    def record!(admin_user:, action:, target: nil, reason: nil, detail: nil, created_at: nil)
      create!(
        admin_user: admin_user,
        action: action.to_s,
        target_type: target&.class&.name,
        target_id: target&.id,
        reason: reason.presence,
        detail: detail.presence,
        created_at: created_at
      )
    end
  end

  # A2 타임라인 표시용 라벨 키(admin.audit.actions.{action})
  def display_label_key
    "admin.audit.actions.#{action}"
  end

  private

  def reason_required_for_destructive_actions
    return unless AuditLog::AUDIT_ACTIONS_REQUIRING_REASON.include?(action.to_s)
    return if reason.present?

    errors.add(:reason, :blank)
  end
end
