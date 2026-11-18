# frozen_string_literal: true

module Subscriptions
  # 플랜 변경 (W4 F8 — PRD 7장 F8: 상향 즉시·기간 유지, 하향 익월 적용.
  # A2 관리자 조치는 사유 필수[ADM-001·PRD 17장 A2 조치 정의] — reason 공백 거절).
  # 하향은 plan 컬럼을 바로 바꾸지 않고 plan_changed(pending) 이벤트로 대기시키고,
  # 결제 갱신(PaymentService) 또는 기간 경과 배치(apply_due_downgrades! — 3-S recurring)에서 확정한다.
  class PlanChangeService
    Result = Data.define(:success?, :subscription, :applied?, :pending?) do
      def self.ok(subscription, applied:, pending:)
        new(success?: true, subscription: subscription, applied?: applied, pending?: pending)
      end

      def self.failure(subscription)
        new(success?: false, subscription: subscription, applied?: false, pending?: false)
      end
    end

    def self.change!(subscription, plan:, operated_by:, reason:)
      new.change!(subscription, plan: plan, operated_by: operated_by, reason: reason)
    end

    # 기간 경과분 하향 일괄 확정 — 3-S recurring 배치 진입점(결제 없이 기간이 지난 경우).
    def self.apply_due_downgrades!(on: Date.current)
      applied = []
      Subscription.find_each do |subscription|
        applied << subscription if apply_pending_downgrade_for!(subscription, on: on)
      end
      applied
    end

    # pending 하향 확정(공용): 결제 갱신은 force: true(갱신 = 익월 경계),
    # 기간 경과 배치는 effective_on 경과분만. 반환: 적용 여부.
    def self.apply_pending_downgrade_for!(subscription, force: false, on: Date.current)
      pending = subscription.pending_downgrade
      return false unless pending

      detail = pending.detail_hash
      effective_on = detail["effective_on"].presence
      if !force && effective_on.present? && Date.iso8601(effective_on) > on
        return false
      end

      subscription.update!(plan: detail["to"])
      subscription.subscription_events.create!(
        event_type: :plan_changed,
        operated_by: pending.operated_by,
        detail: { "direction" => "downgrade", "from" => detail["from"],
                  "to" => detail["to"], "status" => "applied" }.to_json
      )
      true
    end

    def change!(subscription, plan:, operated_by:, reason:)
      target = plan.to_s
      return reject(subscription, :plan_unknown) unless Subscription::PLAN_LIMITS.key?(target.to_sym)
      return reject(subscription, :plan_unchanged) if target == subscription.plan
      return reject(subscription, :plan_change_reason_blank) if reason.to_s.strip.blank?

      # 체험 중에는 기간이 없는 것과 같으므로 상하향 모두 즉시 적용(PRD 11.2 — 만료 시 선택).
      if subscription.trial? || upgrade?(subscription, target) || subscription.current_period_end.blank?
        apply_immediate!(subscription, target, operated_by: operated_by, reason: reason)
      else
        schedule_downgrade!(subscription, target, operated_by: operated_by, reason: reason)
      end
    end

    private

    def upgrade?(subscription, target)
      Subscription::PLAN_LIMITS.fetch(target.to_sym) > subscription.students_limit
    end

    # 상향: 즉시 plan 전환 — 결제 주기(기간)는 유지(PRD 7장 F8).
    def apply_immediate!(subscription, target, operated_by:, reason:)
      detail = {
        "direction" => upgrade?(subscription, target) ? "upgrade" : "downgrade",
        "from" => subscription.plan, "to" => target,
        "reason" => reason.to_s.strip, "status" => "applied"
      }
      subscription.update!(plan: target)
      subscription.subscription_events.create!(
        event_type: :plan_changed, operated_by: operated_by, detail: detail.to_json
      )
      Result.ok(subscription, applied: true, pending: false)
    rescue ActiveRecord::RecordInvalid
      Result.failure(subscription)
    end

    # 하향: plan 컬럼 유지 + plan_changed(pending) 이벤트로 대기 —
    # 적용 시점은 current_period_end(익월 경계).
    def schedule_downgrade!(subscription, target, operated_by:, reason:)
      subscription.subscription_events.create!(
        event_type: :plan_changed, operated_by: operated_by,
        detail: {
          "direction" => "downgrade", "from" => subscription.plan, "to" => target,
          "reason" => reason.to_s.strip,
          "effective_on" => subscription.current_period_end&.to_date&.iso8601,
          "status" => "pending"
        }.to_json
      )
      Result.ok(subscription, applied: false, pending: true)
    end

    def reject(subscription, error_key)
      subscription.errors.add(:base, error_key)
      Result.failure(subscription)
    end
  end
end
