class SessionsController < ApplicationController
  skip_before_action :require_authentication, only: %i[new create]
  # 로그인·로그아웃은 온보딩 게이트 대상 아님(미완료 테넌트도 로그인/로그아웃 가능해야 함)
  skip_before_action :ensure_onboarding_complete

  # 로그인 온라인 대입 완화(WARNING-4): Rails 8 내장 rate limit
  rate_limit to: 10, within: 3.minutes, only: :create

  def new
    @user = User.new
  end

  def create
    session_params = params.expect(session: [ :phone_number, :password ])
    @user = User.find_by(phone_number: normalize_phone(session_params[:phone_number]))

    if @user&.authenticate(session_params[:password])
      start_new_session_for(@user)
      @user.update(last_login_at: Time.current)
      redirect_after_login
    else
      flash.now[:alert] = t("auth.invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    # W1 후속: 로그아웃 시 세션에 남은 CSV 오류내역 캐시 키·참조 제거(서버 캐시 잔존 방지)
    if (csv_key = session[:csv_import_errors_key]).present?
      Rails.cache.delete(csv_key)
      session.delete(:csv_import_errors_key)
    end
    clear_session
    redirect_to new_session_path, status: :see_other, notice: t("auth.signed_out")
  end

  private

  def normalize_phone(value)
    value.to_s.gsub(/[^0-9]/, "")
  end

  def redirect_after_login
    if current_tenant.onboarding_complete?
      redirect_to root_path, status: :see_other
    else
      redirect_to onboarding_step_path(resume_onboarding_step), status: :see_other
    end
  end

  # 가입 직후(step=1) 이탈자 재개용 최소 스텝 보정(CRITICAL-2):
  # step 1은 실제 폼 스텝이 아니므로 첫 폼 스텝(STEPS.first=2)으로 클램프한다.
  def resume_onboarding_step
    [ current_tenant.onboarding_step, OnboardingController::STEPS.first ].max
  end
end
