class LandingController < ApplicationController
  # 랜딩은 비인증 공개(PRD 13장) — 인증 게이트·온보딩 게이트 제외
  skip_before_action :require_authentication
  skip_before_action :ensure_onboarding_complete

  layout "landing" # 앱 셸과 분리 — 하단탭 없음, 랜딩 전용 헤더·푸터

  def show
    # 인증된 원장은 앱 홈(/dashboard)으로 (PRD 13장 구현 확정 사항 — 2026-11-04)
    redirect_to dashboard_path, status: :see_other if authenticated?
    @beta_application = BetaApplication.new
  end
end
