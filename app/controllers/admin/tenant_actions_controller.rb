# 이용자 조치 (PRD 12장 A2·A0 — ADM-001: 사유 없이 실행 불가, 감사 로그 영구 보존).
#
# v1.0 조치:
# - 플랜 수동 변경 — f8 도메인 서비스 경유(Subscriptions::PlanChangeService.change! — 상향/체험 즉시
#   적용·하향 익월 대기 규칙 준수, 2026-11-18 f8 실구현 확인). admin은 사유 가드·감사 로그·결과 안내 담당.
# - 체험 연장(trial_extended) — 1회 최대 30일·이용자별 누적 60일 상한(A2 명세).
#   누적 합계는 본 조치의 감사 로그(detail.days)에서 산출. f8 이벤트 enum에 trial_extended 타입 추가
#   필요(3-S 결선 항목 — 03_implementation §6.3).
# - 계정 정지/해제(tenant_suspended/tenant_resumed) — tenant.status·users 차단 플래그가 없어
#   v1.0은 "조치 이력 기록"까지만(실제 로그인 차단은 후속 — 03_implementation 보고서 명시).
#   suspended 이벤트는 f8 RetryPolicyService#suspend!(past_due 전용)와 구분되는 관리자 기록이므로
#   직접 생성(f8 서비스들과 동일한 이벤트 생성 패턴 — detail JSON·operated_by 마스킹 규약 준수).
#
# 이벤트 장부 규약(f8 SubscriptionEvent): detail은 JSON 문자열, operated_by는 마스킹 setter,
# updated_at 없음(created_at만). admin 이메일은 마스킹 setter를 통과해 그대로 기록된다.
#
# 실패 시 이용자 상세 화면을 422로 재렌더(Turbo 규약) — 데이터 조립은
# Admin::BaseController#prepare_tenant_show! 공용.
class Admin::TenantActionsController < Admin::BaseController
  EXTENSION_MAX_DAYS = 30       # 1회 최대 30일
  EXTENSION_CUMULATIVE_CAP = 60 # 이용자별 누적 60일
  EXTENSION_ALLOWED_STATUSES = %w[trial past_due suspended].freeze

  before_action :set_tenant

  def change_plan
    reason = required_reason
    return render_reason_missing unless reason
    return render_action_failure(t("admin.actions.errors.no_subscription")) unless valid_subscription?

    result = Subscriptions::PlanChangeService.change!(@subscription, plan: params[:plan].to_s,
                                                                operated_by: current_admin_user.email,
                                                                reason: reason)
    return render_action_failure(t("admin.actions.errors.invalid_plan")) unless result.success?

    log_admin_action!(action: "plan_changed", target: @tenant, reason: reason,
                      detail: { plan: params[:plan].to_s, applied: result.applied? })
    redirect_with_notice(change_plan_notice(result))
  end

  def extend_trial
    days = params[:days].to_i
    unless valid_subscription? && @subscription.status.to_s.in?(EXTENSION_ALLOWED_STATUSES)
      return render_action_failure(t("admin.actions.errors.not_extendable"))
    end
    # 누적 한도 초과를 1회 한도(1~30일) 검증보다 먼저 안내(사용량 기준 사유 우선)
    if extended_days_total + days > EXTENSION_CUMULATIVE_CAP
      return render_action_failure(
        t("admin.actions.errors.extension_cap",
          used: extended_days_total, cap: EXTENSION_CUMULATIVE_CAP)
      )
    end
    return render_action_failure(t("admin.actions.errors.invalid_days")) unless days.between?(1, EXTENSION_MAX_DAYS)

    reason = required_reason
    return render_reason_missing unless reason

    new_trial_ends_at = [ current_trial_ends_on, Date.current ].max + days
    @subscription.update!(trial_ends_at: new_trial_ends_at)
    create_subscription_event!(event_type: "trial_extended", reason: reason,
                               detail: { "days" => days,
                                         "trial_ends_at" => new_trial_ends_at.iso8601 })
    log_admin_action!(action: "trial_extended", target: @tenant, reason: reason,
                      detail: { days: days, trial_ends_at: new_trial_ends_at.iso8601 })
    redirect_with_notice(t("admin.actions.notices.trial_extended", days: days))
  end

  # v1.0: 이력 기록만 — 실제 로그인·기능 차단 없음(A2 수용조건의 안내문 전달은 후속).
  # f8 RetryPolicyService#suspend!는 past_due 전이 전용(SUB-002)이라 관리자 기록은 직접 생성.
  def suspend
    reason = required_reason
    return render_reason_missing unless reason

    @subscription = Subscription.find_by(tenant_id: @tenant.id) # 이벤트 장부 기록용(없으면 기록만)
    log_admin_action!(action: "tenant_suspended", target: @tenant, reason: reason)
    create_subscription_event!(event_type: "suspended", reason: reason,
                               detail: { "note" => "관리자 정지 기록(v1.0 — 실차단 후속)" }) if @subscription
    redirect_with_notice(t("admin.actions.notices.suspend_recorded"))
  end

  def resume
    reason = required_reason
    return render_reason_missing unless reason

    log_admin_action!(action: "tenant_resumed", target: @tenant, reason: reason)
    redirect_with_notice(t("admin.actions.notices.resume_recorded"))
  end

  private

  def set_tenant
    @tenant = Tenant.find(params[:tenant_id])
  end

  # [3-S 결합 지점] Subscription(tenant_id 유니크 — f8 구현 확인 완료)
  def valid_subscription?
    @subscription ||= Subscription.find_by(tenant_id: @tenant.id)
    @subscription.present?
  end

  def change_plan_notice(result)
    if result.pending?
      t("admin.actions.notices.plan_change_scheduled")
    else
      t("admin.actions.notices.plan_changed", plan: @subscription.reload.plan)
    end
  end

  def current_trial_ends_on
    @subscription.trial_ends_at.presence&.to_date
  end

  # 누적 연장일 — 본 조치 감사 로그(detail.days) 합계. json 컬럼은 Rails가 Hash로 디코드.
  def extended_days_total
    AuditLog.for_target(@tenant)
            .where(action: "trial_extended")
            .filter_map { |log| log.detail.is_a?(Hash) ? log.detail["days"].to_i : 0 }
            .sum
  end

  # 이벤트 장부 기록 — f8 규약(detail JSON 문자열·operated_by 마스킹 setter·append-only)
  def create_subscription_event!(event_type:, reason:, detail: {}, amount: nil)
    @subscription.subscription_events.create!(
      event_type: event_type,
      amount: amount,
      operated_by: current_admin_user.email,
      detail: { "reason" => reason }.merge(detail.stringify_keys).to_json
    )
  end

  def render_reason_missing
    render_action_failure(t("admin.actions.errors.reason_required"))
  end

  def render_action_failure(message)
    prepare_tenant_show!(@tenant)
    flash.now[:alert] = message
    render "admin/tenants/show", status: :unprocessable_entity
  end

  def redirect_with_notice(message)
    redirect_to admin_tenant_path(@tenant), status: :see_other, notice: message
  end
end
