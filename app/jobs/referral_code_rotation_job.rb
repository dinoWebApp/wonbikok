# 추천 코드 주간 로테이션 (F10 — REF-001: 월요일 09:00, recurring.yml 등록).
# 활성 직원 전원의 유효 코드를 새 코드로 교체(기존 코드 replaced_at — 이력 보존·삭제 없음).
# 가입 매핑은 tenants.referral_code_snapshot이므로 기존 가입자에게 영향 없음. 발송 없는 배치.
class ReferralCodeRotationJob < ApplicationJob
  queue_as :default

  def perform
    rotated = Referral::CodeService.rotate_all!
    Rails.logger.info("[ReferralCodeRotationJob] 주간 코드 로테이션 완료 — rotated=#{rotated}")
  rescue StandardError => e
    Rails.logger.error("[ReferralCodeRotationJob] 로테이션 실패 — error=#{e.class}: #{e.message}")
    raise # Solid Queue 재시도 맡김 — 다음 주 실행 전 재시도로 정합 회복
  end
end
