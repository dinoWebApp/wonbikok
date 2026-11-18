# 구독·결제 관리 (PRD 12장 A3).
#
# - 결제 이력: subscription_events(manual_payment/payment_failed/retry/refund) 기간(월)·유형 필터.
#   이벤트 소스는 f8 구현(2026-11-18 실구현 확인 — detail JSON·operated_by·created_at 전용 장부).
# - 실패 모니터링: past_due 이용자 + 데이터 삭제 예정 D+30 카운트다운.
#   산식은 f8 Subscriptions::RetryPolicyService.data_retention_deadline(최근 past_due 이벤트 + 30일)을
#   단일 경유 — 이벤트 부재 시 subscription.updated_at 근사(화면 명시).
# - 환불: Admin::RefundPolicyService 정책 분기 표시(PRD 11.3) → 확정 시 refund 이벤트 + 감사 로그.
#   refund 이벤트 생성은 f8이 "기록 타입만 정의(서비스 후속)"로 남긴 경로라 직접 생성한다.
#   v1.0은 기록까지 — 실제 이체·구독 상태 즉시 반영·확인 알림톡은 후속(A3 수용조건 중).
# - 매출 집계: 월별 manual_payment 합계(MRR 근사 — 수동 결제 기록 기준, 산식 화면 명시).
class Admin::SubscriptionPaymentsController < Admin::BaseController
  EVENT_TYPES = %w[manual_payment payment_failed retry refund].freeze
  INDEX_LIMIT = 200
  RETENTION_GRACE_DAYS = 30 # SUB-003: 미결제 30일 데이터 보관 후 삭제 예정 안내
  REVENUE_MONTHS = 6

  EventRow = Data.define(:event, :tenant_id, :tenant_name, :plan, :subscription_status, :detail_text)
  PastDueRow = Data.define(:tenant_id, :tenant_name, :plan, :deadline, :days_left)
  RevenueRow = Data.define(:month, :total_amount)

  def index
    @query_month = sanitized_month
    @query_event_type = params[:event_type].presence
    @event_rows = filtered_event_rows
    @past_due_rows = past_due_rows
    @revenue_rows = revenue_rows
  end

  # 환불 접수 폼 — 정책 분기 3종을 미리 계산해 표시(PRD 11.3).
  def refund_new
    @tenant = Tenant.find(params[:tenant_id])
    prepare_refund_form(
      selected_branch: params[:branch].presence,
      amount_override: params[:amount].presence
    )
  end

  # 환불 확정 — 사유 필수(ADM-001). refund 이벤트 + 감사 로그(사유·금액·분기 근거).
  def refund
    @tenant = Tenant.find(params[:tenant_id])
    @subscription = Subscription.find_by(tenant_id: @tenant.id)
    branch = params[:branch].to_s
    amount = params[:amount].to_i
    reason = required_reason

    unless @subscription
      return render_refund_failure(t("admin.subscription_payments.errors.no_subscription"))
    end
    unless Admin::RefundPolicyService::BRANCHES.map(&:to_s).include?(branch)
      return render_refund_failure(t("admin.subscription_payments.errors.invalid_branch"))
    end
    return render_refund_failure(t("admin.actions.errors.reason_required")) if reason.blank?
    if amount.negative?
      return render_refund_failure(t("admin.subscription_payments.errors.invalid_amount"))
    end

    SubscriptionEvent.create!(
      subscription: @subscription, event_type: "refund", amount: amount,
      operated_by: current_admin_user.email, # 마스킹 setter(TEN-003) — 이메일은 그대로 기록
      detail: { "reason" => reason, "branch" => branch,
                "policy_basis" => "PRD 11.3 환불 정책" }.to_json
    )
    log_admin_action!(action: "refund_confirmed", target: @tenant, reason: reason,
                      detail: { branch: branch, amount: amount, plan: @subscription.plan })
    redirect_to admin_subscription_payments_path, status: :see_other,
                notice: t("admin.subscription_payments.notices.refund_recorded")
  end

  private

  def sanitized_month
    month = params[:month].presence || Date.current.strftime("%Y-%m")
    month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/) ? month : Date.current.strftime("%Y-%m")
  end

  def filtered_event_rows
    # includes(subscription: :tenant) — 행 매핑의 plan·status·tenant_name 접근 N+1 해소(W-7)
    scope = SubscriptionEvent.includes(subscription: :tenant)
                             .joins(subscription: :tenant)
                             .where(created_at: month_range)
                             .order(created_at: :desc, id: :desc)
                             .limit(INDEX_LIMIT)
    scope = scope.where(event_type: @query_event_type) if EVENT_TYPES.include?(@query_event_type.to_s)
    scope.map do |event|
      EventRow.new(event: event, tenant_id: event.subscription.tenant_id,
                   tenant_name: event.subscription.tenant.name,
                   plan: event.subscription.plan,
                   subscription_status: event.subscription.status,
                   detail_text: event_detail_text(event))
    end
  end

  def month_range
    first_on = Date.new(@query_month.to_s.split("-").first.to_i, @query_month.to_s.split("-").last.to_i, 1)
    # 해당 월 전체 — Date#all_day는 '그날 하루'라 월 전체 범위로는 쓸 수 없다
    first_on.beginning_of_day..first_on.end_of_month.end_of_day
  end

  # 데이터 삭제 예정 D+30 카운트다운 — f8 RetryPolicyService(최근 past_due 이벤트 + 30일) 단일 경유.
  # past_due 이벤트 부재 시(수동 상태 전이 등) subscription.updated_at 근사(산식 화면 명시).
  def past_due_rows
    Subscription.where(status: :past_due).includes(:tenant).order(:updated_at).map do |subscription|
      deadline = Subscriptions::RetryPolicyService.data_retention_deadline(subscription).presence ||
                 subscription.updated_at.to_date + RETENTION_GRACE_DAYS
      PastDueRow.new(tenant_id: subscription.tenant_id,
                     tenant_name: subscription.tenant.name,
                     plan: subscription.plan,
                     deadline: deadline,
                     days_left: (deadline - Date.current).to_i)
    end
  end

  # 이벤트 장부 비고 — detail JSON에서 사유 위주로 추출(개인정보 원문 미표시, ADM-002)
  def event_detail_text(event)
    detail = event.detail_hash
    detail["reason"].presence ||
      detail.except("policy_basis").map { |key, value| "#{key}: #{value}" }.join(" · ").presence
  end

  # 매출 집계 — 최근 6개월 manual_payment 합계(MRR 근사, 산식 화면 명시).
  def revenue_rows
    sums = SubscriptionEvent.where(event_type: "manual_payment")
                            .where(created_at: REVENUE_MONTHS.months.ago.beginning_of_month..)
                            .group("strftime('%Y-%m', created_at)").sum(:amount)
    (REVENUE_MONTHS - 1).downto(0).map do |ago|
      month = Date.current - ago.months
      key = month.strftime("%Y-%m")
      RevenueRow.new(month: key, total_amount: sums[key].to_i)
    end
  end

  def prepare_refund_form(selected_branch:, amount_override:)
    @subscription = Subscription.find_by(tenant_id: @tenant.id)
    unless @subscription
      redirect_to admin_subscription_payments_path,
                  alert: t("admin.subscription_payments.errors.no_subscription"), status: :see_other
      return
    end

    base_amount = latest_manual_payment_amount
    @base_amount = amount_override&.to_i || base_amount
    @base_amount = base_amount if @base_amount.negative? # 음수 재시도 입력은 폼 재표시에서 기본값으로(정책 서비스 음수 거절 — 422 유지)
    @selected_branch = selected_branch
    @previews = Admin::RefundPolicyService::BRANCHES.index_with do |branch|
      Admin::RefundPolicyService.new(
        amount: @base_amount,
        period_start: @subscription.current_period_start.presence || Time.current.beginning_of_month,
        period_end: @subscription.current_period_end.presence || Time.current
      ).preview(branch)
    end
    @refund_history = SubscriptionEvent.joins(:subscription)
                                       .where(subscriptions: { tenant_id: @tenant.id },
                                              event_type: "refund")
                                       .order(created_at: :desc).limit(10)
  end

  def latest_manual_payment_amount
    SubscriptionEvent.joins(:subscription)
                     .where(subscriptions: { tenant_id: @tenant.id },
                            event_type: "manual_payment")
                     .order(created_at: :desc).first&.amount.to_i
  end

  def render_refund_failure(message)
    @subscription ||= Subscription.find_by(tenant_id: @tenant.id)
    if @subscription.nil?
      # 구독이 없는 테넌트는 폼을 재렌더할 수 없어 안내 후 목록으로 되돌린다(이중 렌더 방지)
      redirect_to admin_subscription_payments_path, alert: message, status: :see_other
      return
    end

    prepare_refund_form(selected_branch: params[:branch].presence, amount_override: params[:amount].presence)
    flash.now[:alert] = message
    render :refund_new, status: :unprocessable_entity
  end
end
