# 체험 만료 D-7 알림 배치 (W4 F8 — SUB-004 과금 통지, PRD 11.2).
# 조회 진입점: Subscription.trial_expiring(기본 7일 — f8 모델 스코프 재사용).
# v1.0: 솔라피 실발송 없음(SIMULATED) — 알림 대상·내용을 로그에 기록하고
# 캐시 마커로 체험 기간당 1회만 기록한다(일중·기간 중 중복 방지).
# 실발송 전환(P1) 시 솔라피는 Notifications 계열 Service + Job 경유로 호출하고,
# 구독 단위 발송 유일성은 별도 발송 이력(스키마 확장)으로 관리한다 —
# message_logs는 청구 단위(invoice_id NOT NULL)라 구독 알림 장부로 오용하지 않는다(MSG-001).
class SubscriptionTrialReminderJob < ApplicationJob
  queue_as :default

  def perform(within = 7.days)
    notified = Subscription.trial_expiring(within).filter_map do |subscription|
      next if already_notified?(subscription)

      Rails.logger.info(
        "[SubscriptionTrialReminder] SIMULATED tenant=#{subscription.tenant_id} " \
        "subscription=#{subscription.id} " \
        "trial_ends_on=#{subscription.trial_ends_at.to_date} " \
        "remain_days=#{subscription.trial_remain_days}"
      )
      mark_notified!(subscription)
      subscription.id
    end
    Rails.logger.info("[SubscriptionTrialReminder] SIMULATED notified=#{notified.size}")
  end

  private

  # SIMULATED 기록(로그)의 체험 기간당 1회 보장용 마커 — 체험 종료 후 자동 만료.
  def already_notified?(subscription)
    Rails.cache.exist?(marker_key(subscription))
  end

  def mark_notified!(subscription)
    ttl = [ subscription.trial_ends_at - Time.current, 1.minute ].max
    Rails.cache.write(marker_key(subscription), true, expires_in: ttl)
  end

  def marker_key(subscription)
    "sub_trial_d7_notified:#{subscription.id}:#{subscription.trial_ends_at.to_date}"
  end
end
