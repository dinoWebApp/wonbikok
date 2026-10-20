class DashboardController < ApplicationController
  # 대시보드 — 온보딩 게이트는 ApplicationController 공통 적용(W1 후속)
  def show
    unpaid = current_tenant.invoices.remindable # F6 미납 대상(취소·제외 제외)
    @unpaid_count = unpaid.size
    @unpaid_total = unpaid.sum("base_amount + adjustment_amount")
    # 다가오는 리마인더: 단계 도래(경과·월말) & 미발송 건
    @upcoming_reminders = unpaid.count { |invoice| Reminders::Scheduler.due_stage_for(invoice) }
  end
end
