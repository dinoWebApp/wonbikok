# 미납 리마인더 (W2 F6).
# 모든 조회는 current_tenant 스코프(TEN-001). 문구는 ko.yml + 원장 커스텀.
# 흐름: 미납 목록(index) → 즉시 발송 미리보기(preview) → 발송(dispatch) — 이력은 MessageLog.
# 설정(settings)·발송 이력(history)·원생별 제외 토글(MSG-004).
class RemindersController < ApplicationController
  before_action :set_student, only: :toggle_exclusion

  # 미납 현황: 원생·금액·경과일·마지막 리마인더 발송일·제외 여부 + 필터
  def index
    scope = current_tenant.invoices
                          .where.not(status: :CANCELLED) # INV-003
                          .where.not(due_on: nil)
                          .where(due_on: ...Date.current)
                          .includes(student: :guardians)
                          .order(:due_on, :id)
    scope = scope.joins(:student).where(students: { excluded_from_reminders: true }) if excluded_filter?
    @invoices = scope
    @excluded_only = excluded_filter?
    @last_reminder_at = last_reminder_map(@invoices)
  end

  # 즉시 발송 미리보기: 수신자(마스킹 — TEN-003)·내용 확인 후 발송
  def preview
    @previews = selected_invoices.map do |invoice|
      stage = Reminders::Scheduler.due_stage_for(invoice) || :d3
      template_type = :"reminder_#{stage}"
      builder = Solapi::MessageBuilder.reminder(invoice:, tenant: current_tenant,
                                                template_type:, to: "")
      { invoice:, stage:, template_type:, text: builder.preview_text,
        phone: invoice.student.primary_guardian&.phone_number, # TEN-003: 뷰에서 masked_phone 표시
        missing: invoice.student.primary_guardian.blank?,
        excluded: invoice.student.excluded_from_reminders? }
    end
  end

  # 즉시 발송 — Dispatcher 경유(이력 기록, MSG-001 유일성은 Dispatcher가 처리)
  # NOTE: 액션명 dispatch는 ActionController::Metal#dispatch와 충돌해 deliver_now 사용
  def deliver_now
    invoices = selected_invoices
    template_types = invoices.group_by { |invoice| :"reminder_#{Reminders::Scheduler.due_stage_for(invoice) || :d3}" }

    queued = duplicated = missing = 0
    template_types.each do |template_type, group|
      result = Notifications::Dispatcher.new(tenant: current_tenant)
                                        .dispatch(group, template_type:,
                                                  send_at: Reminders::Scheduler.send_time_for(current_tenant))
      queued += result.queued
      duplicated += result.duplicated
      missing += result.recipients_missing
    end

    redirect_to reminders_path, status: :see_other,
               notice: t("reminders.notices.dispatched", queued:, duplicated:, missing:)
  end

  # 리마인더 설정: 톤·단계 토글·발송 시각·커스텀 문구(단계별 미리보기 동반)
  def settings
    @tenant = current_tenant
    @previews = stage_previews(@tenant)
  end

  def update_settings
    @tenant = current_tenant
    if @tenant.update(reminder_params)
      redirect_to reminder_settings_path, status: :see_other, notice: t("reminders.notices.settings_saved")
    else
      @previews = stage_previews(@tenant)
      flash.now[:alert] = t("errors.form")
      render :settings, status: :unprocessable_entity
    end
  end

  # 발송 이력: 리마인더 건(원생별·일시별) — 필터(원생)
  def history
    @logs = current_tenant.message_logs.reminder
                          .includes(:student, :invoice)
                          .order(created_at: :desc)
    @logs = @logs.where(student_id: params[:student_id]) if params[:student_id].present?
    @filter_students = current_tenant.students.order(:name)
  end

  # 원생별 리마인더 제외/해제 — 해제 즉시 자동 발송 배제(MSG-004)
  def toggle_exclusion
    @student.update!(excluded_from_reminders: !@student.excluded_from_reminders?)
    redirect_to reminders_path, status: :see_other,
               notice: t(@student.excluded_from_reminders? ? "reminders.notices.excluded" : "reminders.notices.included",
                         name: @student.name)
  end

  private

  def set_student
    @student = current_tenant.students.find(params[:student_id]) # TEN-001
  end

  def excluded_filter?
    params[:excluded] == "1"
  end

  # 리마인더 설정(톤·단계 토글·발송 시각·단계별 커스텀 문구)
  def reminder_params
    params.expect(tenant: [
      :remind_tone, :remind_d3_enabled, :remind_d7_enabled, :remind_month_end_enabled,
      :remind_send_hour, :remind_custom_text_d3, :remind_custom_text_d7, :remind_custom_text_month_end
    ])
  end

  def selected_invoices
    ids = Array(params[:invoice_ids]).filter_map { |id| Integer(id, exception: false) }
    current_tenant.invoices.where(id: ids).remindable # TEN-001 + 대상 규칙 재적용
  end

  def last_reminder_map(invoices)
    logs = current_tenant.message_logs.reminder
                         .where(invoice_id: invoices.map(&:id)).order(:created_at)
    logs.group_by(&:invoice_id).transform_values { |group| group.last.created_at }
  end

  def stage_previews(tenant)
    Tenant::REMINDER_STAGES.index_with do |stage|
      Solapi::MessageBuilder.reminder(invoice: Reminders::SampleInvoice.instance,
                                      tenant:, template_type: :"reminder_#{stage}", to: "")
                            .preview_text
    end
  end
end
