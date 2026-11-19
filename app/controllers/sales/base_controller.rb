# 영업 직원 대시보드 공통 베이스 (F10 — 관리자·원장과 분리된 제3 인증 체계, PRD 7장 F10).
#
# - 세션 키 sales_rep_id(별도) — 관리자(admin_user_id)·원장(session)과 상호 간섭 없음.
#   원장 앱(Authentication)·Admin::BaseController를 상속하지 않는다(권한 격리 — 관리자 권한 없음).
# - REF-005 스코프 격리: 모든 조회는 current_sales_rep 경유만 — 타 직원 데이터 접근 경로 없음.
# - REF-007: 정지 계정은 세션 유무와 무관하게 접근 차단(로그인 단계 차단 + 세션 재확인 이중 방어).
class Sales::BaseController < ActionController::Base
  allow_browser versions: :modern

  layout "sales"

  before_action :require_sales_rep!

  helper_method :current_sales_rep

  private

  def require_sales_rep!
    rep = current_sales_rep
    redirect_to new_sales_session_path, alert: t("sales.sessions.login_required") if rep.nil?
  end

  def current_sales_rep
    return @current_sales_rep if defined?(@current_sales_rep)

    @current_sales_rep = if session[:sales_rep_id].present?
                           SalesRep.active.find_by(id: session[:sales_rep_id])
    end
  end
end
