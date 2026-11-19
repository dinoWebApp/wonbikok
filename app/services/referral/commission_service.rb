# frozen_string_literal: true

module Referral
  # 수수료 원장 집계·발생 (F10 — REF-003 역할 정책·REF-004 스냅샷 보존).
  #
  # - accrue_on_payment!: 결제(manual_payment) 성공 시점에만 ledger 생성 — 실제 징수액(할인 후) 기준,
  #   rate는 rep의 결제 시점 유효 요율 스냅샷(이후 요율 변경 소급 없음).
  #   캡 판정은 피판매 테넌트 가입일(tenants.created_at) 기준 — sales 12개월 경과 결제는 미생성,
  #   officer는 무기한(nil).
  # - 집계(월 요약·수령 예상·연도 누적)는 대시보드·관리자 화면이 서비스 경유만 사용(뷰 쿼리 금지).
  # - mark_paid!: 월 후불 지급 확정 — 사유 필수 + 감사 로그(ADM-001·REF-007 정신).
  # - v1.0: 환불 시 ledger 역분(차감)은 후속 과제 — refund 이벤트와의 정산은 구현 보고서에 명시.
  class CommissionService
    MonthlyRow = Data.define(:month, :count, :base_amount, :amount, :paid_amount, :pending_amount)
    YearlySummary = Data.define(:year, :rows, :total_amount, :paid_amount, :pending_amount)

    class << self
      # 결제 발생 수수료 ledger 생성(pending). 대상 외(비추천·캡 경과·금액 0)는 nil — 결제에는 영향 없음.
      # subscription.tenant는 belongs_to 로드 경유(TEN-001 — 스코프 우회 없음).
      def accrue_on_payment!(subscription, paid_amount, source_event: nil, at: Time.current)
        tenant = subscription&.tenant
        return nil unless tenant&.referred?

        sales_rep = tenant.referred_by_sales_rep
        return nil if sales_rep.nil? || !within_cap?(tenant, sales_rep, at: at)

        base = paid_amount.to_i
        return nil if base <= 0

        rate = sales_rep.effective_commission_rate # REF-004 결제 시점 스냅샷
        sales_rep.commission_ledgers.create!(
          tenant: tenant,
          month: at.to_date.strftime("%Y-%m"),
          base_amount: base,
          rate: rate,
          amount: (base * rate).round,
          status: :pending,
          source_subscription_event_id: source_event
        )
      end

      # REF-003 캡: 결제 시점(at)이 테넌트 가입일 + 캡 개월 이내(경계일 포함). officer(nil)는 무기한.
      def within_cap?(tenant, sales_rep, at: Time.current)
        cap = sales_rep.effective_cap_months
        return true if cap.nil?

        at <= tenant.created_at + cap.months
      end

      # 월 단위 요약(관리자 직원 상세·지급 확정 근거)
      def monthly_summary(sales_rep, month)
        ledgers = sales_rep.commission_ledgers.for_month(month)
        MonthlyRow.new(
          month: month, count: ledgers.count, base_amount: ledgers.sum(:base_amount),
          amount: ledgers.sum(:amount),
          paid_amount: ledgers.paid.sum(:amount), pending_amount: ledgers.pending.sum(:amount)
        )
      end

      # 이번달 수령 예상 = 전월(확정 결제) ledger 합계 — 월 단위 후불 정산 표시 규약.
      def expected_this_month(sales_rep, on: Date.current)
        sales_rep.commission_ledgers.for_month(on.prev_month.strftime("%Y-%m")).sum(:amount)
      end

      # 연도별 누적(월별 행 + 연도 합계·지급/미지급 구분 — 직원 대시보드·관리자 요약 공용)
      def yearly_summary(sales_rep, year)
        ledgers = sales_rep.commission_ledgers.for_year(year)
        rows = ledgers.distinct.order(:month).pluck(:month).map do |month|
          monthly = ledgers.for_month(month)
          MonthlyRow.new(
            month: month, count: monthly.count, base_amount: monthly.sum(:base_amount),
            amount: monthly.sum(:amount),
            paid_amount: monthly.paid.sum(:amount), pending_amount: monthly.pending.sum(:amount)
          )
        end
        YearlySummary.new(
          year: year, rows: rows, total_amount: ledgers.sum(:amount),
          paid_amount: ledgers.paid.sum(:amount), pending_amount: ledgers.pending.sum(:amount)
        )
      end

      # 지급 확정(ADM-001 — 사유 필수 + 감사 로그). 이미 paid인 건은 재확정하지 않는다(멱등).
      # 반환: 실제 확정 여부(이미 paid면 false).
      def mark_paid!(ledger, admin_user:, reason:)
        if reason.to_s.strip.blank?
          raise ArgumentError, "지급 확정 사유는 필수입니다(ADM-001)"
        end
        return false if ledger.paid?

        ActiveRecord::Base.transaction do
          ledger.update!(status: :paid, paid_at: Time.current)
          AuditLog.record!(
            admin_user: admin_user, action: "commission_paid", target: ledger, reason: reason,
            detail: { "sales_rep_id" => ledger.sales_rep_id, "tenant_id" => ledger.tenant_id,
                      "month" => ledger.month, "amount" => ledger.amount }
          )
        end
        true
      end

      # 피판매 전체 월별 결제액(manual_payment 실제 징수액 — 할인 후 금액, 취소 제외).
      # 월별 결제액 카드(직원 대시보드 ③) 소스 — ledger와 별개로 캡 경과분까지 포함한 총 결제 실적.
      # 반환: { "YYYY-MM" => 금액 } (SQLite strftime — 프로젝트 단일 DB 규약).
      def monthly_charged_totals(sales_rep, year: Date.current.year)
        tenant_ids = sales_rep.referred_tenants.ids
        return {} if tenant_ids.empty?

        SubscriptionEvent.joins(:subscription)
                         .where(event_type: :manual_payment, subscriptions: { tenant_id: tenant_ids })
                         .where("strftime('%Y-%m', subscription_events.created_at) LIKE ?", "#{year}-%")
                         .group(Arel.sql("strftime('%Y-%m', subscription_events.created_at)"))
                         .sum(:amount)
      end
    end
  end
end
