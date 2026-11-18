# 대기 중 플랜 하향 일괄 확정 배치 (W4 F8 — 익월 적용 규약, config/recurring.yml 매일 1회).
# Subscriptions::PlanChangeService.apply_due_downgrades!에 위임 —
# 기간(current_period_end)이 경과한 구독의 plan_changed(pending)만 applied 확정(멱등).
class SubscriptionDowngradeApplyJob < ApplicationJob
  queue_as :default

  def perform
    applied = Subscriptions::PlanChangeService.apply_due_downgrades!
    Rails.logger.info("[SubscriptionDowngradeApply] applied=#{applied.size}")
  end
end
