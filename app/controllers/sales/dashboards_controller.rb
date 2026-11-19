# 영업 직원 대시보드 (F10 — PRD 7장 F10: 코드·피판매 목록·월별 결제액·수령 예상·연도 누적).
#
# - REF-005: 데이터는 Sales::DashboardService(본인 rep 스코프) 단일 경유 — 타 직원 데이터 조회 불가.
# - 뷰 쿼리 금지: 모든 집계는 서비스에서 완성해 @변수 주입.
# - 연도 선택은 query 파라미터(사용자 입력 — 정수 클램프만, 조회 범위는 본인 데이터로 한정).
class Sales::DashboardsController < Sales::BaseController
  YEARS_BACK = 3

  def show
    @service = Sales::DashboardService.new(current_sales_rep)
    @selected_year = sanitized_year
    @code = @service.active_code
    @tenant_rows = @service.tenant_rows
    @monthly_charged_rows = @service.monthly_charged_rows(@selected_year)
    @expected_amount = @service.expected_this_month
    @yearly = @service.yearly_summary(@selected_year)
  end

  private

  # 표시 가능 연도로 클램프(현재 연도 ~ 현재-3년) — 조작 무의미화(스코프는 본인 데이터로 한정됨)
  def sanitized_year
    current_year = Date.current.year
    requested = params[:year].to_i
    return current_year if requested.zero?

    requested.clamp(current_year - YEARS_BACK, current_year)
  end
end
