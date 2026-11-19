# 영업 직원 관리 (F10 — PRD 12장 A2 확장).
#
# - CRUD: role·타이틀·수수료율(0.05~0.30)·캡 개월 설정. 생성 시 첫 추천 코드 즉시 발급(REF-001).
# - 정지/해제: 사유 필수(ADM-001 — AuditLog 2차 방어) + 정지 시 유효 코드 즉시 무효화(REF-007).
# - 수수료 요약: 월별·연 누적(Referral::CommissionService 경유 — 뷰 쿼리 금지) + 지급 확정(paid, 사유·감사 로그).
# - ADM-002: 직원 email·name은 업무 연락처로 마스킹하지 않는다(개인정보 기본 마스킹 대상 외 —
#   피판매 테넌트 목록은 상호만 표시하고 원장 개인정보는 미노출).
class Admin::SalesStaffsController < Admin::BaseController
  SUMMARY_MONTHS = 6

  def index
    @sales_staffs = SalesRep.order(:id)
  end

  def show
    @sales_staff = SalesRep.find(params[:id])
    prepare_commission_summary
  end

  def new
    @sales_staff = SalesRep.new(role: "sales")
  end

  def create
    @sales_staff = SalesRep.new(sales_staff_params)

    if @sales_staff.save
      code = Referral::CodeService.issue_for!(@sales_staff) # 첫 유효 코드 발급(7일 — REF-001)
      log_admin_action!(action: "sales_staff_created", target: @sales_staff,
                        detail: { role: @sales_staff.role, first_code_issued: true })
      redirect_to admin_sales_staff_path(@sales_staff), status: :see_other,
                  notice: t("admin.sales_staffs.notices.created", code: code)
    else
      flash.now[:alert] = t("errors.form")
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @sales_staff = SalesRep.find(params[:id])
  end

  def update
    @sales_staff = SalesRep.find(params[:id])

    if @sales_staff.update(sales_staff_params)
      log_admin_action!(action: "sales_staff_updated", target: @sales_staff,
                        detail: { role: @sales_staff.role })
      redirect_to admin_sales_staff_path(@sales_staff), status: :see_other,
                  notice: t("admin.sales_staffs.notices.updated")
    else
      flash.now[:alert] = t("errors.form")
      render :edit, status: :unprocessable_entity
    end
  end

  # REF-007: 정지 — 사유 필수 + 유효 코드 즉시 무효화(SalesRep#suspend! 단일 경유) + 로그인 차단.
  def suspend
    @sales_staff = SalesRep.find(params[:id])
    reason = required_reason
    return render_reason_missing unless reason

    @sales_staff.suspend!(reason)
    log_admin_action!(action: "sales_rep_suspended", target: @sales_staff, reason: reason)
    redirect_with_notice(t("admin.sales_staffs.notices.suspended"))
  end

  def resume
    @sales_staff = SalesRep.find(params[:id])
    reason = required_reason
    return render_reason_missing unless reason

    @sales_staff.resume!
    log_admin_action!(action: "sales_rep_resumed", target: @sales_staff, reason: reason)
    redirect_with_notice(t("admin.sales_staffs.notices.resumed"))
  end

  # 수수료 지급 확정(pending → paid) — 사유 필수 + 감사 로그(CommissionService#mark_paid! 단일 경유).
  # member 라우트(/admin/sales_staffs/:id/mark_paid) — 대상 직원은 params[:id], ledger는 쿼리 파라미터.
  def mark_paid
    @sales_staff = SalesRep.find(params[:id])
    ledger = @sales_staff.commission_ledgers.find(params[:ledger_id])
    reason = required_reason
    return render_reason_missing unless reason

    if Referral::CommissionService.mark_paid!(ledger, admin_user: current_admin_user, reason: reason)
      redirect_with_notice(t("admin.sales_staffs.notices.paid", month: ledger.month))
    else
      redirect_with_notice(t("admin.sales_staffs.notices.already_paid"))
    end
  end

  private

  # 월별 요약(최근 N개월) + 당해 연도 누적 + 최근 ledger + 피판매 — 뷰에 완성 값만 주입(뷰 쿼리 금지)
  def prepare_commission_summary
    @monthly_rows = (0...SUMMARY_MONTHS).map do |i|
      month = Date.current.months_ago(i).strftime("%Y-%m")
      Referral::CommissionService.monthly_summary(@sales_staff, month)
    end
    @yearly = Referral::CommissionService.yearly_summary(@sales_staff, Date.current.year)
    @recent_ledgers = @sales_staff.commission_ledgers.order(month: :desc, id: :desc).limit(20) # 최근순
    @referred_tenants = @sales_staff.referred_tenants.order(created_at: :desc).limit(50) # W-2 이관
  end

  def sales_staff_params
    permitted = params.expect(sales_rep: [
      :name, :email, :password, :password_confirmation, :role, :title,
      :commission_rate, :commission_cap_months
    ])
    # 수정 시 빈 비밀번호 = 기존 유지(has_secure_password allow_nil) — 빈 문자열은 제거해 전달
    if permitted[:password].blank? && permitted[:password_confirmation].blank?
      permitted = permitted.except(:password, :password_confirmation)
    end
    permitted
  end

  def render_reason_missing
    flash.now[:alert] = t("admin.actions.errors.reason_required")
    prepare_commission_summary
    render :show, status: :unprocessable_entity
  end

  def redirect_with_notice(message)
    redirect_to admin_sales_staff_path(@sales_staff), status: :see_other, notice: message
  end
end
