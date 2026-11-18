class DashboardController < ApplicationController
  # 대시보드·마감 리포트 (W4 F7 — PRD 7장 F7).
  # 집계는 Dashboard::SummaryService가 전담한다(뷰 질의 금지). 온보딩 게이트는
  # ApplicationController 공통 적용(W1 후속).
  def show
    @month = parsed_month
    @summary = Dashboard::SummaryService.new.call(tenant: current_tenant, month: @month)
  end

  # 월간 마감 리포트 (HTML — PDF 저장은 후속 과제: _workspace/01_plan.md §0.2).
  # 라우트는 3-S 통합에서 추가(get "dashboard/report") — f7은 액션·뷰만 제공.
  def report
    @month = parsed_month
    @summary = Dashboard::SummaryService.new.call(tenant: current_tenant, month: @month)
  end

  private

  # month 파라미터는 형식 검증 기반 수용 — 무효·공백은 당월 기본
  # (invoices#set_month·payments#sanitized_month와 동일 패턴, F5 C5 준용).
  def parsed_month
    month = params[:month].to_s
    month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/) ? month : Date.current.strftime("%Y-%m")
  end
end
