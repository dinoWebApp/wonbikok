# 관리자 콘솔 공통 베이스 (PRD 12장 A0 — 원장 앱과 분리된 별도 인증 체계·데스크톱 우선).
#
# - 원장 앱(ApplicationController/Authentication)과 인증 체계를 공유하지 않는다:
#   세션 키 admin_user_id(별도), 2단계 인증(Admin::SessionsController), 관리자 전용 레이아웃.
# - ADM-002: 개인정보는 기본 마스킹 — 마스킹 helper를 이 컨트롤러에 두어 모든 관리자 화면이 경유.
# - ADM-001: 파괴적 조치 기록은 AuditLog.record! 경유(사유 필수는 AuditLog 모델 2차 방어 +
#   각 조치 컨트롤러의 reason 가드).
class Admin::BaseController < ActionController::Base
  allow_browser versions: :modern

  layout "admin"

  before_action :require_admin!

  helper_method :current_admin_user
  helper_method :admin_mask_phone, :admin_mask_email, :admin_mask_business_number, :admin_mask_name

  private

  def require_admin!
    redirect_to new_admin_session_path, alert: t("admin.sessions.login_required") unless current_admin_user
  end

  def current_admin_user
    return @current_admin_user if defined?(@current_admin_user)

    @current_admin_user = if session[:admin_user_id].present?
                            AdminUser.find_by(id: session[:admin_user_id])
    end
  end

  # 조치 기록 통합 진입점(ADM-001) — 감사 로그에 개인정보 원문을 넣지 않는다(ADM-002).
  def log_admin_action!(action:, target: nil, reason: nil, detail: nil)
    AuditLog.record!(admin_user: current_admin_user, action: action, target: target,
                     reason: reason, detail: detail)
  end

  # 사유 없는 파괴적 조치 거부(ADM-001) — 유효 시 사유 문자열, 무효 시 nil.
  def required_reason
    params[:reason].to_s.strip.presence
  end

  # 이용자 상세 화면 데이터 조립 — TenantsController#show와 조치 실패 422 재렌더
  # (Admin::TenantActionsController)가 공용. 뷰는 이 메서드가 채운 @변수만 사용(뷰 쿼리 금지).
  def prepare_tenant_show!(tenant)
    @tenant = tenant
    @subscription = Subscription.find_by(tenant_id: tenant.id) # [3-S 결합 지점] 01_plan §2 가정
    @owner_users = tenant.users.order(:id)
    @students_count = tenant.students.count
    @plan_limit = @subscription&.students_limit # f8 구현: effective_plan 기준 상한(체험 중 스탠다드 개방)
    @last_login_at = @owner_users.maximum(:last_login_at)
    @last_message_at = tenant.message_logs.maximum(:created_at)
    @last_receipt_at = tenant.cash_receipts.maximum(:created_at)
    @month_message_count = tenant.message_logs
                                  .where(created_at: Time.current.beginning_of_month..)
                                  .where(status: [ :SENT, :FALLBACK_SENT, :SIMULATED ]).count
    @month_receipt_issued_count = tenant.cash_receipts
                                        .where(state: :issued,
                                               issued_at: Time.current.beginning_of_month..).count
    @timeline = Admin::TimelineService.new(tenant).call
    # 정지 기록 표시용(v1.0 — 실제 로그인 차단 없음, 조치 이력만 관리) — 최신 정지/해제 기록 기준
    last_suspension_action = AuditLog.for_target(tenant)
                                     .where(action: %w[tenant_suspended tenant_resumed])
                                     .order(:created_at, :id).last
    @suspension_recorded = last_suspension_action&.action == "tenant_suspended"
  end

  # ── 개인정보 마스킹 helper(ADM-002·TEN-003) — 뷰에서 반드시 경유 ──
  def admin_mask_phone(value)
    digits = value.to_s.gsub(/[^0-9]/, "")
    return "미설정" if digits.blank?
    return "#{digits[0, 3]}-****-#{digits[-4, 4]}" if digits.match?(/\A01[016789]\d{7,8}\z/)

    "*" * [ digits.length, 3 ].min
  end

  def admin_mask_email(value)
    email = value.to_s
    return "미설정" if email.blank?

    local, domain = email.split("@", 2)
    return "*" * email.length if domain.nil?

    "#{local.to_s[0, 2]}#{'*' * [ local.to_s.length - 2, 0 ].max}@#{domain}"
  end

  def admin_mask_business_number(value)
    digits = value.to_s.gsub(/[^0-9]/, "")
    return "미설정" if digits.blank?

    "#{digits[0, 3]}-**-***#{digits[-2, 2]}"
  end

  def admin_mask_name(value)
    name = value.to_s.strip
    return "미설정" if name.blank?

    "#{name[0]}#{'*' * [ name.length - 1, 1 ].max}"
  end
end
