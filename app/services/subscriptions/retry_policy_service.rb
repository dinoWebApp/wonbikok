# frozen_string_literal: true

module Subscriptions
  # 결제 실패 재시도 프레임 (W4 F8 — SUB-002·SUB-003·MSG-003).
  # 실패 기록: payment_failed 이벤트 + 다음 재시도 예약(retry 이벤트, D+1/D+3/D+5).
  # 3회 실패: past_due 전이(결제 유예) — 이후 재시도 스케줄 없음(MSG-003 무한 반복 금지).
  # suspend!: past_due 상태에서 SUB-002 일시정지 전이(데이터 유지·조회 허용) —
  #   실행 주체는 A2 관리자 조치 또는 3-S recurring 배치.
  # data_retention_deadline: past_due 시점 + 30일(SUB-003 데이터 보관 카운트다운 계산만 —
  #   실제 삭제 배치는 후속). 실제 결제 재시도 청구(Portone)는 P1 — 본 서비스는 상태 전이·
  #   스케줄 데이터 계산만 담당한다. 통지(SUB-004)는 앱 배너(show 화면) + 알림톡은 후속 잡.
  class RetryPolicyService
    RETRY_OFFSET_DAYS = [ 1, 3, 5 ].freeze # PRD 7장 F8: D+1/D+3/D+5
    MAX_FAILURES = 3
    RETENTION_DAYS = 30 # SUB-003: 미결제 30일 데이터 보관

    Result = Data.define(:success?, :subscription, :events, :status_changed?) do
      def self.ok(subscription, events, status_changed:)
        new(success?: true, subscription: subscription, events: events, status_changed?: status_changed)
      end

      def self.failure(subscription)
        new(success?: false, subscription: subscription, events: [], status_changed?: false)
      end
    end

    def self.record_failure!(subscription, amount: nil, failed_at: Time.current, operated_by: nil)
      new.record_failure!(subscription, amount: amount, failed_at: failed_at, operated_by: operated_by)
    end

    def self.suspend!(subscription, reason: nil, operated_by: nil)
      new.suspend!(subscription, reason: reason, operated_by: operated_by)
    end

    # SUB-003: 데이터 보관 만료일(past_due 전환 시점 + 30일) — past_due 이력 없으면 nil
    def self.data_retention_deadline(subscription)
      event = subscription.subscription_events.where(event_type: :past_due).order(:id).last
      return nil unless event

      event.created_at.to_date + RETENTION_DAYS
    end

    # SUB-003 카운트다운(일) — 만료 경과 시 음수, past_due 이력 없으면 nil
    def self.remaining_retention_days(subscription, on: Date.current)
      deadline = data_retention_deadline(subscription)
      return nil unless deadline

      (deadline - on).to_i
    end

    # 재시도 스케줄(일자 배열) — 실패 시각 기준 D+1/D+3/D+5 (프레임 참조용 공개 계산)
    def self.retry_schedule(failed_at)
      RETRY_OFFSET_DAYS.map { |offset| failed_at.to_date + offset }
    end

    # 체험 만료 → past_due 전이(SUB-003 진입 — 3-S recurring 배치 진입점, 매일 1회).
    # 대상: 체험이 끝났는데 결제 기록이 없는 trial 구독(결제 유예 30일 데이터 보관 시작).
    def self.expire_due_trials!(on: Date.current)
      transitioned = []
      Subscription.trial.where(trial_ends_at: ...Time.current).find_each do |subscription|
        next if subscription.subscription_events.exists?(event_type: :manual_payment)
        next unless transition_to_past_due!(subscription, failures: 0,
                                                      reason: "trial_expired", operated_by: nil)

        transitioned << subscription
      end
      transitioned
    end

    # past_due 전이 + past_due 이벤트(보관 만료일 기록) — 재시도 3회 소진·체험 만료 공용.
    # 이미 past_due면 nil(중복 전이 없음 — MSG-003 무한 반복 금지 정신).
    def self.transition_to_past_due!(subscription, failures:, reason:, operated_by:)
      return nil if subscription.past_due?

      deadline = RETENTION_DAYS.days.from_now
      subscription.update!(status: :past_due)
      subscription.subscription_events.create!(
        event_type: :past_due,
        operated_by: operated_by,
        detail: {
          "failures" => failures,
          "reason" => reason,
          "retention_deadline" => deadline.to_date.iso8601
        }.to_json
      )
    end

    # 마지막 수동 결제(manual_payment) 이후 누적 실패 횟수 — 결제 성공 시 카운터 리셋
    def self.failure_count(subscription)
      scope = subscription.subscription_events.where(event_type: :payment_failed)
      last_payment = subscription.subscription_events.where(event_type: :manual_payment).order(:id).last
      scope = scope.where("id > ?", last_payment.id) if last_payment
      scope.count
    end

    def record_failure!(subscription, amount: nil, failed_at: Time.current, operated_by: nil)
      return Result.failure(subscription) unless recordable?(subscription)

      attempt = self.class.failure_count(subscription) + 1
      events = []
      status_changed = false
      ActiveRecord::Base.transaction do
        events << create_payment_failed_event(subscription, attempt: attempt,
                                                        failed_at: failed_at, amount: amount,
                                                        operated_by: operated_by)
        if attempt >= MAX_FAILURES
          past_due_event = self.class.transition_to_past_due!(
            subscription, failures: attempt, reason: "retries_exhausted", operated_by: operated_by
          )
          status_changed = past_due_event.present?
          events << past_due_event if past_due_event
        else
          events << create_retry_event(subscription, attempt: attempt, failed_at: failed_at,
                                                     operated_by: operated_by)
        end
      end
      Result.ok(subscription, events, status_changed: status_changed)
    rescue ActiveRecord::RecordInvalid
      Result.failure(subscription)
    end

    # SUB-002 일시정지 전이 — past_due(재시도 3회 소진·유예) 상태에서만 허용
    def suspend!(subscription, reason: nil, operated_by: nil)
      return Result.failure(subscription) unless subscription.past_due?

      ActiveRecord::Base.transaction do
        subscription.update!(status: :suspended)
        event = subscription.subscription_events.create!(
          event_type: :suspended,
          operated_by: operated_by,
          detail: {
            "reason" => reason.to_s.strip.presence,
            "note" => "데이터 유지·조회 허용(SUB-002)"
          }.to_json
        )
        Result.ok(subscription, [ event ], status_changed: true)
      end
    rescue ActiveRecord::RecordInvalid
      Result.failure(subscription)
    end

    private

    # 결제 실패 기록 대상: 이용 중(active)·결제 유예(past_due)만 —
    # 체험 중(청구 없음)·정지·해지 상태의 실패 기록은 의미가 없어 거절.
    def recordable?(subscription)
      subscription.active? || subscription.past_due?
    end

    def create_payment_failed_event(subscription, attempt:, failed_at:, amount:, operated_by:)
      exhausted = attempt >= MAX_FAILURES
      subscription.subscription_events.create!(
        event_type: :payment_failed,
        amount: amount,
        operated_by: operated_by,
        detail: {
          "attempt" => attempt,
          "failed_at" => failed_at.iso8601,
          "next_retry_on" => exhausted ? nil : retry_on_after(attempt, failed_at)&.iso8601,
          "retries_exhausted" => exhausted
        }.to_json
      )
    end

    # 다음 재시도 예약 기록(retry 이벤트) — 실제 청구 실행 잡은 P1(3-S recurring 후보)
    def create_retry_event(subscription, attempt:, failed_at:, operated_by:)
      subscription.subscription_events.create!(
        event_type: :retry,
        operated_by: operated_by,
        detail: {
          "attempt" => attempt + 1,
          "scheduled_on" => retry_on_after(attempt, failed_at).iso8601
        }.to_json
      )
    end

    # attempt번째 실패 이후의 재시도일 — D+1/D+3/D+5 (attempt 1 → D+1)
    def retry_on_after(attempt, failed_at)
      failed_at.to_date + RETRY_OFFSET_DAYS.fetch(attempt - 1)
    end
  end
end
