# 체험 만료 → 결제 유예 전환 배치 (W4 F8 — SUB-003 진입, config/recurring.yml 매일 1회).
# Subscriptions::RetryPolicyService.expire_due_trials!에 위임 —
# 결제 기록이 없는 만료 체험만 past_due 전이(멱등 — 재실행 무전이).
class SubscriptionTrialExpireJob < ApplicationJob
  queue_as :default

  def perform
    transitioned = Subscriptions::RetryPolicyService.expire_due_trials!
    Rails.logger.info("[SubscriptionTrialExpire] past_due transitioned=#{transitioned.size}")
  end
end
