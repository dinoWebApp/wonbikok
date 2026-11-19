# 영업 직원 로그인 (F10 — 이메일+비밀번호 단일 단계·OTP 없음·관리자 권한 없는 제한 계정).
#
# - 세션 키 sales_rep_id — 관리자·원장 세션과 별도.
# - 로그인 5회 실패 잠금(AdminUser 동일 규약 — 해제는 콘솔).
# - REF-007: 정지 계정은 비밀번호가 맞아도 로그인 차단(사유는 관리자 조치 시 안내 기록).
# - 대입 완화: rate_limit 10회/3분(원장·관리자 동일 규약).
class Sales::SessionsController < Sales::BaseController
  skip_before_action :require_sales_rep!, only: %i[new create]

  rate_limit to: 10, within: 3.minutes, only: :create

  def new
    @sales_rep = SalesRep.new
  end

  def create
    session_params = params.expect(sales_session: [ :email, :password ])
    sales_rep = SalesRep.find_by(email: normalize_email(session_params[:email]))

    if sales_rep&.locked?
      @sales_rep = SalesRep.new(email: session_params[:email])
      flash.now[:alert] = t("sales.sessions.locked_notice")
      render :new, status: :unprocessable_entity
    elsif sales_rep&.authenticate(session_params[:password])
      if sales_rep.suspended?
        blocked_login(sales_rep)
      else
        reset_session # 세션 고정 방어(W-1 — Admin::SessionsController 동일 패턴)
        session[:sales_rep_id] = sales_rep.id
        sales_rep.reset_failed_attempts!
        redirect_to sales_dashboard_path, status: :see_other, notice: t("sales.sessions.signed_in")
      end
    else
      sales_rep&.register_failed_attempt!
      @sales_rep = SalesRep.new(email: session_params[:email])
      flash.now[:alert] = t("sales.sessions.invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:sales_rep_id)
    redirect_to new_sales_session_path, status: :see_other, notice: t("sales.sessions.signed_out")
  end

  private

  # REF-007: 정지 계정 로그인 차단 — 실패 카운트를 올리지 않는다(정지는 잠금과 별개 조치).
  def blocked_login(sales_rep)
    @sales_rep = SalesRep.new(email: sales_rep.email)
    flash.now[:alert] = t("sales.sessions.suspended_notice")
    render :new, status: :unprocessable_entity
  end

  def normalize_email(value)
    value.to_s.strip.downcase
  end
end
