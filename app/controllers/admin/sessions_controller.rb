# 관리자 로그인 (PRD 12장 A0 — 이메일+비밀번호 1단계 → OTP 6자리 2단계).
#
# - 세션은 원장 앱과 별도 키(admin_user_id·admin_pending_user_id) — 관리자/원장 동시 로그인 간섭 없음.
# - 로그인 5회 실패(비밀번호·OTP 합산) 시 잠금 — 해제는 콘솔(AdminUser#unlock!, 1인 운영).
# - 감사 로그(A0): login / login_failure / account_locked — 계정 미확인 기록은 admin_user nil 허용.
# - 대입 완화: 원장 세션 컨트롤러와 동일한 rate_limit(10회/3분) 적용.
class Admin::SessionsController < Admin::BaseController
  skip_before_action :require_admin!, only: %i[new create create_otp]

  rate_limit to: 10, within: 3.minutes, only: %i[create create_otp]

  def new
    clear_pending_admin!
    @admin_user = AdminUser.new
  end

  # 1단계: 이메일+비밀번호 — 성공 시 OTP 단계(2단계) 폼 렌더, 세션에 예비 키만 저장.
  def create
    step1_params = params.expect(admin_session: [ :email, :password ])
    user = AdminUser.find_by(email: normalize_email(step1_params[:email]))

    if user&.locked?
      AuditLog.record!(admin_user: user, action: "login_failure", detail: { stage: "password", locked: true })
      @admin_user = AdminUser.new(email: step1_params[:email])
      flash.now[:alert] = t("admin.sessions.locked_notice")
      render :new, status: :unprocessable_entity
    elsif user&.authenticate(step1_params[:password])
      session[:admin_pending_user_id] = user.id
      @admin_user = user
      @otp_code = ""
      render :otp
    else
      register_login_failure!(user, stage: "password")
      @admin_user = AdminUser.new(email: step1_params[:email])
      flash.now[:alert] = t("admin.sessions.invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  # 2단계: OTP 검증 — 성공 시 최종 로그인(실패 카운트 리셋), 실패 시 잠금 절차.
  def create_otp
    user = pending_admin_user
    unless user
      redirect_to new_admin_session_path, alert: t("admin.sessions.session_expired"), status: :see_other
      return
    end

    if Admin::OtpService.verify?(user, params[:otp_code])
      user.reset_failed_attempts!
      reset_session # 세션 고정 방어(W-1) — OTP 성공 시 새 세션 발급 후 최종 키만 재설정
      session[:admin_user_id] = user.id
      AuditLog.record!(admin_user: user, action: "login")
      redirect_to admin_dashboard_path, status: :see_other, notice: t("admin.sessions.signed_in")
    else
      locked_now = register_login_failure!(user, stage: "otp") # account_locked 기록은 이 메서드 단일 경유(W-3)
      if user.reload.locked?
        clear_pending_admin!
        @admin_user = AdminUser.new
        flash.now[:alert] = t("admin.sessions.locked_notice")
        render :new, status: :unprocessable_entity
      else
        @admin_user = user
        @otp_code = ""
        flash.now[:alert] = t("admin.sessions.invalid_otp")
        render :otp, status: :unprocessable_entity
      end
    end
  end

  def destroy
    AuditLog.record!(admin_user: current_admin_user, action: "logout") if current_admin_user
    clear_pending_admin!
    session.delete(:admin_user_id)
    redirect_to new_admin_session_path, status: :see_other, notice: t("admin.sessions.signed_out")
  end

  private

  # 로그인 실패 기록 — login_failure + 잠금 전환 시 account_locked(단일 경유, W-3).
  # 반환값: 이번 실패로 잠금에 도달했는지(호출측은 재기록하지 않는다).
  def register_login_failure!(user, stage:)
    return false unless user

    locked_now = user.register_failed_attempt!
    AuditLog.record!(admin_user: user, action: "login_failure", detail: { stage: stage })
    AuditLog.record!(admin_user: user, action: "account_locked") if locked_now
    locked_now
  end

  # 1단계 통과(비밀번호 확인) 후 아직 최종 로그인 전인 계정 — 잠금 시 무효.
  def pending_admin_user
    return nil if session[:admin_pending_user_id].blank?

    user = AdminUser.find_by(id: session[:admin_pending_user_id])
    return nil if user.nil? || user.locked?

    user
  end

  def clear_pending_admin!
    session.delete(:admin_pending_user_id)
  end

  def normalize_email(value)
    value.to_s.strip.downcase
  end
end
