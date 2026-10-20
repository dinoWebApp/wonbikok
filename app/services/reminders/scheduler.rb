# frozen_string_literal: true

# F6 미납 리마인더 스케줄러 — ReminderDispatchJob(매일 09:00)이 호출.
#
# 대상 판정(W2 임시 규칙 — PRD 14장): Invoice.remindable
#   - status IN (SENT, UNPAID, OVERDUE) & due_on 경과 & 완납 기록 없음(Payment W3 확장)
#   - CANCELLED 제외(INV-003) — 상태 목록에 부재
#   - student.excluded_from_reminders=false(MSG-004: 제외 설정 즉시 자동 발송 배제)
#
# 단계: D+3 / D+7 / 월말 D-1(target_month 말일 전날). 각 단계는 template_type이 상이
# (reminder_d3/d7/month_end)하므로 MSG-001 유일성(청구 × 템플릿 유형)이 단계당 1회를 강제.
#
# MSG-006: 발송 시각은 테넌트 remind_send_hour(9~17) — 호출 시각이 허용 시간대(9~17시)를
# 벗어나면 다일 오전으로 이월. 야간 발송 없음.
#
# 문구: 원장 커스텀 문구 우선, 없음 시 톤(부드러움/표준/공식) 기본 템플릿 — MessageBuilder 경유
# (원장상호·전화 포함 — MSG-005). 실호출은 MessageSendJob이 연습 모드/키 미설정 시 SIMULATED.
class Reminders::Scheduler
  StageResult = Data.define(:stage, :dispatched, :duplicated, :recipients_missing)

  # stage → 활성화 토글, template_type(단계별 상이 — MSG-001이 단계당 1회 강제). 판정은 due_stage_for.
  STAGES = [
    { stage: :d3, enabled: :remind_d3_enabled, template_type: :reminder_d3 },      # 기한 경과 3~6일
    { stage: :d7, enabled: :remind_d7_enabled, template_type: :reminder_d7 },      # 기한 경과 7일 이상(월말 전)
    { stage: :month_end, enabled: :remind_month_end_enabled, template_type: :reminder_month_end } # 월말 D-1 이후
  ].freeze

  def initialize(tenant: nil, date: Date.current)
    @tenants = tenant ? [ tenant ] : Tenant.all
    @date = date
  end

  # 전체 테넌트(배치) 또는 단일 테넌트(수동 트리거) 실행 — 단계별 결과 배열 반환
  def dispatch_all
    @tenants.flat_map { |tenant| dispatch_for(tenant) }
  end

  def dispatch_for(tenant)
    STAGES.filter_map { |stage| dispatch_stage(tenant, stage) }
  end

  # 단계 도달 판정(단독 노출 — 미리보기·즉시 발송 단계 선택용)
  # d3는 기한 경과일이 3일 이상일 때만(PRD F6 'D+3' — 경과 1~2일은 미발송).
  # month_end(대상월 말일 전날 이후)·d7(경과 7일 이상)은 기존 판정 유지.
  def self.due_stage_for(invoice, date: Date.current)
    return nil if invoice.due_on.blank? || invoice.due_on >= date

    year, month = invoice.target_month.split("-").map { |part| Integer(part, 10) }
    month_end_minus1 = Date.new(year, month, -1) - 1
    return :month_end if date >= month_end_minus1

    days = (date - invoice.due_on).to_i
    return :d7 if days >= 7
    return :d3 if days >= 3

    nil
  end

  private

  def dispatch_stage(tenant, spec)
    return StageResult.new(stage: spec[:stage], dispatched: 0, duplicated: 0, recipients_missing: 0) unless stage_enabled?(tenant, spec)

    invoices = eligible_invoices(tenant, spec)
    return StageResult.new(stage: spec[:stage], dispatched: 0, duplicated: 0, recipients_missing: 0) if invoices.empty?

    result = Notifications::Dispatcher.new(tenant:)
                                .dispatch(invoices, template_type: spec[:template_type], send_at: schedule_time(tenant))

    Rails.logger.info("[Reminder] #{spec[:stage]} dispatched=#{result.queued} " \
                      "duplicated=#{result.duplicated} missing=#{result.recipients_missing} " \
                      "tenant=#{tenant.id} date=#{@date}")

    StageResult.new(stage: spec[:stage], dispatched: result.queued, duplicated: result.duplicated,
                    recipients_missing: result.recipients_missing)
  end

  # 단계 활성화 토글(도래 판정은 eligible_invoices의 기한 조건이 담당)
  def stage_enabled?(tenant, spec)
    tenant.public_send(spec[:enabled])
  end

  def eligible_invoices(tenant, spec)
    # 단계 판정은 due_stage_for 단일 기준(d3: 경과 3~6일, d7: 7일 이상·월말 전, month_end: 월말 D-1 이후)
    scope = tenant.invoices.remindable.select { |invoice| self.class.due_stage_for(invoice, date: @date) == spec[:stage] }
    # 각 단계당 청구별 1회 — 이미 발송 이력이 있는 청구 제외(MSG-001 사전 걸러내기)
    sent_ids = tenant.message_logs.where(template_type: spec[:template_type])
                                  .where(invoice_id: scope.map(&:id)).pluck(:invoice_id)
    scope.reject { |invoice| sent_ids.include?(invoice.id) }
  end

  # MSG-006: 설정 시각(9~17시) 예약. 호출이 허용 시간대 내면 즉시(또는 설정 시각),
  # 야간이면 다일 오전 설정 시각으로 이월. 수동 즉시 발송도 동일 적용.
  def self.send_time_for(tenant)
    hour = tenant.remind_send_hour.clamp(9, 17)
    today_at = Time.zone.now.change(hour:, min: 0, sec: 0)
    return today_at if today_at > Time.zone.now
    return Time.zone.now if (9..17).cover?(Time.zone.now.hour)

    1.day.from_now.change(hour:, min: 0, sec: 0)
  end

  private

  def schedule_time(tenant)
    self.class.send_time_for(tenant)
  end
end
