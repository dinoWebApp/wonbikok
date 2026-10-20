class DashboardController < ApplicationController
  # 대시보드 준비 페이지 — W1에서는 온보딩 완료 확인용 최소 화면(본격 대시보드는 W2)
  def show
    redirect_if_onboarding_incomplete
  end
end
