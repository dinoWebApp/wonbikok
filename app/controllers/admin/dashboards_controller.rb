# 운영 대시보드 (PRD 12장 A1 — 하루 3분 안에 어제 어긋난 것·오늘 할 일 파악).
#
# 수용조건 대응:
# - 발송/발행 실패는 실시간(요청 시점 집계), 지표 카드는 조회 시점 산식(일 1회 갱신 허용 범위).
# - 모든 수치는 화면에 기간·정의(산식)를 명시(A1 수용조건) — i18n 문구에 산식 포함.
# - 외부 서비스 상태는 SIMULATED 표시(실제 핑 금지 — 플레이스홀더 구조, A1 수용조건의 자동 반영은 후속).
# - 추이 그래프는 숫자 표로 대체(01_plan §7 리스크 2 — 차트 라이브러리 없음, 후속).
#
# 뷰 쿼리 금지 원칙 — 모든 집계는 본 컨트롤러 private 메서드에서 완료해 @변수로 주입.
class Admin::DashboardsController < Admin::BaseController
  RECENT_WINDOW = 24.hours
  TREND_DAYS = 7
  REVENUE_MONTHS = 6

  MetricRow = Data.define(:label_key, :value, :formula_key, :link_url, :link_enabled)

  def show
    @ops_status = build_ops_status
    @metric_rows = build_metric_rows
    @trend_rows = build_trend_rows
    @queues = build_queues
    @service_banner = build_service_banner
  end

  private

  def build_ops_status
    # 괄호 필수 — 무괄호 endless range 뒤의 `{`는 해시 리터럴(범위 끝)로 파싱된다
    window = (RECENT_WINDOW.ago..)
    {
      message_failed: MessageLog.where(status: :FAILED).where(updated_at: window).count,
      receipt_failed: CashReceipt.where(state: :failed).where(updated_at: window).count,
      receipt_processing: CashReceipt.where(state: :processing).count,
      receipt_cancel_pending: CashReceipt.where(state: :cancel_pending).count
    }
  end

  # 지표 카드 — 산식(formula_key)을 화면에 병기한다(A1: 지표의 기간과 정의 명시).
  def build_metric_rows
    [
      MetricRow.new(label_key: "admin.dashboard.metrics.mau", value: mau_approximation,
                    formula_key: "admin.dashboard.formulas.mau",
                    link_url: admin_tenants_path, link_enabled: true),
      MetricRow.new(label_key: "admin.dashboard.metrics.trial_d7", value: trial_expiring_soon_count,
                    formula_key: "admin.dashboard.formulas.trial_d7",
                    link_url: nil, link_enabled: false),
      MetricRow.new(label_key: "admin.dashboard.metrics.paid_conversion",
                    value: paid_conversion_percent,
                    formula_key: "admin.dashboard.formulas.paid_conversion",
                    link_url: nil, link_enabled: false),
      MetricRow.new(label_key: "admin.dashboard.metrics.monthly_cancellations",
                    value: monthly_cancelled_count,
                    formula_key: "admin.dashboard.formulas.monthly_cancellations",
                    link_url: nil, link_enabled: false)
    ]
  end

  # MAU 근사 — 최근 30일 세션 생성 수(Session 테이블 기반, 로그인 시 생성).
  def mau_approximation
    Session.where(created_at: 30.days.ago..).distinct.count(:user_id)
  end

  # 체험 만료 D-7 예정 — f8 Subscription#trial_expiring?(within:)(2026-11-18 실구현 확인).
  def trial_expiring_soon_count
    Subscription.where(status: :trial).select { |subscription| subscription.trial_expiring?(within: 7.days) }.size
  rescue NameError, ActiveRecord::StatementInvalid
    nil # f8 미병합 환경 폴백 — 3-S에서 제거
  end

  # 유료 전환율(%) — active / (trial + active), 소수점 반올림. 분모 0이면 nil(표시 "-").
  def paid_conversion_percent
    counts = Subscription.group(:status).count
    denominator = counts["trial"].to_i + counts["active"].to_i
    return nil if denominator.zero?

    (counts["active"].to_i * 100.0 / denominator).round
  rescue ActiveRecord::StatementInvalid
    nil
  end

  # 월 해지 — 당월 내 상태가 cancelled로 관측된 구독 수(전환 시점 미기록 → updated_at 근사, 산식 명시).
  def monthly_cancelled_count
    Subscription.where(status: :cancelled, updated_at: Time.current.beginning_of_month..).count
  rescue ActiveRecord::StatementInvalid
    nil
  end

  # 추이(숫자 표) — 최근 7일 일별 발송/발행 생성 건수.
  def build_trend_rows
    message_by_day = MessageLog.group("date(created_at)").count
    receipt_by_day = CashReceipt.group("date(created_at)").count
    (TREND_DAYS - 1).downto(0).map do |ago|
      day = Date.current - ago.days
      TrendRow.new(date: day, message_count: message_by_day[day.to_s].to_i,
                   receipt_count: receipt_by_day[day.to_s].to_i)
    end
  end

  TrendRow = Data.define(:date, :message_count, :receipt_count)

  # 대응 대기 큐 — 결제 실패 방치(past_due)·발행 실패 방치(24시간 경과 failed).
  # 클릭 시 A3(index)로 이동 / A5는 미구현(비활성 표시).
  def build_queues
    past_due_subscriptions = Subscription.where(status: :past_due).includes(:tenant)
                                         .order(:updated_at).limit(10)
    [
      QueueItem.new(label_key: "admin.dashboard.queues.past_due", count: past_due_count,
                    formula_key: "admin.dashboard.formulas.past_due",
                    link_url: admin_subscription_payments_path,
                    link_enabled: true,
                    items: past_due_subscriptions.map do |subscription|
                      { tenant_name: subscription.tenant.name,
                        url: admin_tenant_path(subscription.tenant) }
                    end),
      QueueItem.new(label_key: "admin.dashboard.queues.stale_receipt_failures",
                    count: stale_receipt_failure_count,
                    formula_key: "admin.dashboard.formulas.stale_receipt_failures",
                    link_url: nil, link_enabled: false, items: [])
    ]
  end

  def past_due_count
    Subscription.where(status: :past_due).count
  rescue ActiveRecord::StatementInvalid
    nil
  end

  QueueItem = Data.define(:label_key, :count, :formula_key, :link_url, :link_enabled, :items)

  # 발행 실패 방치 — failed 상태로 24시간 이상 경과(집계 시점 기준, 산식 명시). A5는 미구현.
  def stale_receipt_failure_count
    CashReceipt.where(state: :failed).where(updated_at: ...RECENT_WINDOW.ago).count
  end

  # 외부 서비스 상태 배너 — SIMULATED(미확인) 고정. 실제 핑/헬스체크 호출 금지(플레이스홀더).
  def build_service_banner
    %w[solapi portone barobill].map do |service|
      ServiceStatus.new(name_key: "admin.dashboard.services.#{service}",
                        state: "simulated",
                        state_key: "admin.dashboard.service_states.simulated")
    end
  end

  ServiceStatus = Data.define(:name_key, :state, :state_key)
end
