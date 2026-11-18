# frozen_string_literal: true

module Subscriptions
  # 30일 무료체험 자동 시작 (W4 F8 — PRD 7장 F8·14장 W4 확정 블록).
  # 가입 트랜잭션(RegistrationsController)에서 호출 — 카드 등록 없음.
  # 멱등: 구독이 이미 있으면 아무 것도 하지 않고 성공 반환(가입 재시도·동시 가입 레이스 방어).
  class TrialService
    Result = Data.define(:success?, :subscription, :created?) do
      def self.ok(subscription, created:)
        new(success?: true, subscription: subscription, created?: created)
      end

      def self.failure(subscription)
        new(success?: false, subscription: subscription, created?: false)
      end
    end

    def self.start_for!(tenant)
      new.start_for!(tenant)
    end

    def start_for!(tenant)
      existing = Subscription.find_by(tenant_id: tenant.id) # TEN-001
      return Result.ok(existing, created: false) if existing

      subscription = Subscription.create!(
        tenant: tenant,
        plan: :standard, # 체험 중 스탠다드 전체 개방(PRD 11.2) — 만료 시 플랜 선택
        status: :trial,
        trial_started_at: Time.current,
        trial_ends_at: Subscription::TRIAL_DAYS.days.from_now,
        current_period_start: Time.current,
        current_period_end: Subscription::TRIAL_DAYS.days.from_now
      )
      subscription.subscription_events.create!(
        event_type: :trial_started,
        detail: { "days" => Subscription::TRIAL_DAYS }.to_json
      )
      Result.ok(subscription, created: true)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # 동시 가입 레이스(tenant_id 유니크) 등으로 생성 실패 — 가입 자체는 막지 않는다(호출측 로그).
      Result.failure(Subscription.find_by(tenant_id: tenant.id))
    end
  end
end
