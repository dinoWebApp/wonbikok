# 이용자 전사정 타임라인 (PRD 12장 A2 — 가입→온보딩→결제→조치 이력을 시간순 단일 타임라인 표시).
#
# 병합 소스:
#   1. 가입(tenants.created_at)·온보딩 상태 — 온보딩 완료 시점은 별도 기록이 없어 v1.0에서는
#      가입 시점에 앵커한 "현재 상태" 항목으로 표시(완료 시점 기록은 후속 과제)
#   2. subscription_events — [3-S 결합 지점] f8이 구현하는 이벤트 소스(01_plan §2 가정).
#      subscription_id → subscriptions.tenant_id 조인으로 테넌트별 조회
#   3. message_logs — 발송(템플릿 유형·상태)
#   4. cash_receipts — 발행(상태·금액)
#   5. audit_logs — 관리자 조치·열람(ADM-001)
#
# 개인정보는 라벨·식별자 수준만 노출(ADM-002) — note에 휴대폰번호 원문 등을 넣지 않는다.
module Admin
  class TimelineService
    DEFAULT_LIMIT = 100

    Entry = Data.define(:occurred_at, :kind, :label_key, :note, :amount, :seq)

    # 항목 표시 순서 결정용 — 같은 시각이면 최근 삽입(seq)이 위로
    SEQ_BASE = 0

    def initialize(tenant, limit: DEFAULT_LIMIT)
      @tenant = tenant
      @limit = limit
    end

    # 최신순(desc) 정렬된 Entry 배열
    def call
      entries.sort_by { |entry| [ entry.occurred_at, entry.seq ] }
             .reverse
             .first(@limit)
    end

    private

    def entries
      base_entries + subscription_entries + message_entries +
        cash_receipt_entries + audit_entries
    end

    def base_entries
      list = [
        Entry.new(occurred_at: @tenant.created_at, kind: :tenant_created,
                  label_key: "admin.timeline.kinds.tenant_created", note: @tenant.name,
                  amount: nil, seq: SEQ_BASE),
        onboarding_entry
      ]
      list.compact
    end

    # 온보딩 완료 시점 미기록 — 현재 상태를 가입 시점 항목에 병기(v1.0 축소)
    def onboarding_entry
      return nil unless @tenant.onboarding_complete?

      Entry.new(occurred_at: @tenant.created_at, kind: :onboarding,
                label_key: "admin.timeline.kinds.onboarding_state",
                note: "step #{@tenant.onboarding_step}/#{Tenant::ONBOARDING_FINAL_STEP}",
                amount: nil, seq: SEQ_BASE + 1)
    end

    # f8 Subscription/SubscriptionEvent 실구현 참조(2026-11-18 확인):
    # - Subscription: tenant_id 유니크, plan, status, trial_ends_at, current_period_start/end
    # - SubscriptionEvent: belongs_to :subscription, event_type(enum), amount, detail(JSON 문자열 —
    #   detail_hash로 파싱), operated_by, created_at(note 컬럼 없음 — 사유는 detail.reason)
    def subscription_entries
      events = SubscriptionEvent.joins(:subscription)
                                .where(subscriptions: { tenant_id: @tenant.id })
                                .order(:created_at, :id)
      events.map.with_index do |event, index|
        Entry.new(occurred_at: event.created_at, kind: :subscription_event,
                  label_key: "admin.timeline.subscription_events.#{event.event_type}",
                  note: event_detail_text(event), amount: event.amount, seq: 10_000 + index)
      end
    rescue ActiveRecord::StatementInvalid, NameError
      # SubscriptionEvent 미구현 환경(f8 미병합)에서도 A2 화면이 깨지지 않도록 건너뜀 — 3-S에서 제거
      []
    end

    # detail JSON에서 표시용 비고 추출 — 사유 우선, 개인정보 원문 미표시(ADM-002)
    def event_detail_text(event)
      detail = event.detail_hash
      detail["reason"].presence ||
        detail.except("policy_basis").map { |key, value| "#{key}: #{value}" }.join(" · ").presence
    rescue StandardError
      nil
    end

    def message_entries
      logs = @tenant.message_logs.order(:created_at, :id)
      logs.map.with_index do |log, index|
        Entry.new(occurred_at: log.created_at, kind: :message,
                  label_key: "admin.timeline.message_templates.#{log.template_type}",
                  note: log.status, amount: nil, seq: 20_000 + index)
      end
    end

    def cash_receipt_entries
      receipts = @tenant.cash_receipts.order(:created_at, :id)
      receipts.map.with_index do |receipt, index|
        Entry.new(occurred_at: receipt.issued_at || receipt.created_at, kind: :cash_receipt,
                  label_key: "admin.timeline.cash_receipt_states.#{receipt.state}",
                  note: receipt.mgt_key, amount: receipt.amount, seq: 30_000 + index)
      end
    end

    def audit_entries
      logs = AuditLog.for_target(@tenant).order(:created_at, :id)
      logs.map.with_index do |log, index|
        Entry.new(occurred_at: log.created_at, kind: :audit,
                  label_key: log.display_label_key,
                  note: log.reason.presence, amount: nil, seq: 40_000 + index)
      end
    end
  end
end
