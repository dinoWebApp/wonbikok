# frozen_string_literal: true

module Sales
  # 영업 직원 대시보드 데이터 조립 (F10 — REF-005 스코프 격리: 전 조회가 본인 rep 스코프 경유만).
  # 컨트롤러는 본 서비스 단일 경유 — 뷰 쿼리 금지·타 직원 데이터 조회 경로 자체가 없다.
  #
  # TEN 마스킹 준용: 피판매 목록은 상호·가입일·플랜·구독 상태만 노출(원장 개인명·전화 등
  # 개인정보는 아예 조회·전달하지 않는다 — 마스킹이 아닌 미수집).
  class DashboardService
    TenantRow = Data.define(:tenant_name, :joined_on, :plan, :status)
    MonthlyChargedRow = Data.define(:month, :total_amount)

    DASHBOARD_TENANT_LIMIT = 100

    attr_reader :sales_rep

    def initialize(sales_rep)
      @sales_rep = sales_rep
    end

    def active_code
      @sales_rep.active_referral_code
    end

    # 피판매 사용자 목록(가입일·플랜·구독 상태) — 본인 스코프만(REF-005).
    # W-3: 구독 표시 includes로 프리로드 — 행당 쿼리(N+1) 방지.
    def tenant_rows
      @sales_rep.referred_tenants.includes(:subscription)
                .order(created_at: :desc).limit(DASHBOARD_TENANT_LIMIT).map do |tenant|
        subscription = tenant.subscription
        TenantRow.new(
          tenant_name: tenant.name,
          joined_on: tenant.created_at.to_date,
          plan: subscription&.plan,
          status: subscription&.status
        )
      end
    end

    # 월별 결제액(피판매 전체 — 실제 징수액, 선택 연도 12개월 행 완성)
    def monthly_charged_rows(year)
      totals = Referral::CommissionService.monthly_charged_totals(@sales_rep, year: year)
      (1..12).map do |m|
        month = format("%04d-%02d", year, m)
        MonthlyChargedRow.new(month: month, total_amount: totals[month].to_i)
      end
    end

    # 이번달 수령 예상(전월 확정 결제 기준 — 월 후불 정산 규약)
    def expected_this_month
      Referral::CommissionService.expected_this_month(@sales_rep)
    end

    # 연도별 누적 수수료(월별 행 + 지급/미지급 합계)
    def yearly_summary(year)
      Referral::CommissionService.yearly_summary(@sales_rep, year)
    end
  end
end
