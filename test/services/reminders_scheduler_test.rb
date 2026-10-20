# frozen_string_literal: true

# 미납 리마인더 스케줄러 테스트 — 단계 판정 경계(C2 회귀), MSG-004/006, MSG-001 사전 필터
class RemindersSchedulerTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  setup do
    @tenant = Tenant.create!(name: "리마인더 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant)
    @date = Date.new(2026, 10, 20)
  end

  def invoice_due(days_ago, month: @date.strftime("%Y-%m"))
    invoice_on(month, due_on: @date - days_ago)
  end

  def invoice_on(month, due_on:)
    invoice = create_invoice(@tenant, @student, due_on: due_on, target_month: month)
    invoice.update!(status: :SENT, sent_at: 1.month.ago)
    invoice
  end

  def stage_for(days_ago, month: @date.strftime("%Y-%m"))
    Reminders::Scheduler.due_stage_for(
      Invoice.new(due_on: @date - days_ago, target_month: month), date: @date
    )
  end

  # 단계 판정 경계 — Phase 6 C2 회귀(d3는 경과 3일 이상만). 판정은 읽기 전용이라 미저장 객체 사용.
  test "단계 판정: 경과 1일 2일은 미발송(nil)이다" do
    assert_nil stage_for(1)
    assert_nil stage_for(2)
  end

  test "단계 판정: 경과 3일과 6일은 d3다" do
    assert_equal :d3, stage_for(3)
    assert_equal :d3, stage_for(6)
  end

  test "단계 판정: 경과 7일은 d7이다" do
    assert_equal :d7, stage_for(7)
    assert_equal :d7, stage_for(30)
  end

  test "단계 판정: 기한 미경과·기한 없음은 nil이다" do
    assert_nil Reminders::Scheduler.due_stage_for(
      Invoice.new(due_on: @date + 5, target_month: @date.strftime("%Y-%m")), date: @date
    )
    assert_nil Reminders::Scheduler.due_stage_for(
      Invoice.new(due_on: nil, target_month: @date.strftime("%Y-%m")), date: @date
    )
  end

  # 월말 D-1 경계 — d7 도래 전이라도 대상월 말일 전날부터 month_end
  test "단계 판정: 월말 D-1부터 month_end다" do
    invoice = invoice_on("2026-10", due_on: Date.new(2026, 10, 28))
    assert_equal :month_end,
                 Reminders::Scheduler.due_stage_for(invoice, date: Date.new(2026, 10, 30)) # 10/30 == 말일-1
    assert_nil Reminders::Scheduler.due_stage_for(invoice, date: Date.new(2026, 10, 29)) # D+1은 미발송
    invoice_nov = invoice_on("2026-11", due_on: Date.new(2026, 11, 27))
    assert_equal :month_end,
                 Reminders::Scheduler.due_stage_for(invoice_nov, date: Date.new(2026, 11, 29)) # 11/30 말일-1
  end

  # d7 윈도우가 month_end에 흡수되는 달(기한이 말일 근접) — month_end 단독
  test "단계 판정: 말일 근접 기한은 month_end가 단독 발송된다" do
    invoice = invoice_on("2026-10", due_on: Date.new(2026, 10, 24)) # 경과 6일(=d3 구간)이지만
    assert_equal :month_end,
                 Reminders::Scheduler.due_stage_for(invoice, date: Date.new(2026, 10, 30)) # 월말 우선
  end

  # F6 배치: d3 대상 발송 — QUEUED 로그 1건(단계 템플릿)
  test "F6 배치는 d3 대상에 reminder_d3 발송을 예약한다" do
    invoice = invoice_due(4)

    results = Reminders::Scheduler.new(tenant: @tenant, date: @date).dispatch_for(@tenant)

    dispatched = results.select { |stage| stage.dispatched.positive? }
    assert_equal 1, dispatched.size
    assert_equal :d3, dispatched.first.stage
    log = invoice.message_logs.sole
    assert_equal "reminder_d3", log.template_type
    assert_equal "QUEUED", log.status
  end

  # MSG-001: 배치 재실행 멱등 — 재발송 없음
  test "MSG-001 배치 재실행 시 중복 발송이 없다" do
    invoice_due(4)
    Reminders::Scheduler.new(tenant: @tenant, date: @date).dispatch_for(@tenant)

    results = Reminders::Scheduler.new(tenant: @tenant, date: @date).dispatch_for(@tenant)

    assert_equal 0, results.sum(&:dispatched)
    assert_equal 0, results.sum(&:duplicated) # 사전 필터로 대상 자체가 탈락
  end

  # MSG-004: 제외 설정 원생은 즉시 배제(토글 직후 배치 대상 탈락)
  test "MSG-004 제외 토글 직후 배치 대상에서 탈락한다" do
    invoice = invoice_due(4)
    @student.update!(excluded_from_reminders: true)

    results = Reminders::Scheduler.new(tenant: @tenant, date: @date).dispatch_for(@tenant)

    assert_equal 0, results.sum(&:dispatched)
    assert_not MessageLog.exists?(invoice_id: invoice.id)
  end

  # INV-003: 취소 청구는 리마인더 대상 제외
  test "INV-003 취소 청구는 리마인더가 발송되지 않는다" do
    invoice = invoice_due(4)
    invoice.cancel!("오발행")

    results = Reminders::Scheduler.new(tenant: @tenant, date: @date).dispatch_for(@tenant)

    assert_equal 0, results.sum(&:dispatched)
    assert_not MessageLog.exists?(invoice_id: invoice.reload.id)
  end

  # 단계 토글 OFF — 해당 단계 발송 없음
  test "단계 토글이 OFF면 해당 단계는 발송하지 않는다" do
    @tenant.update!(remind_d3_enabled: false)
    invoice = invoice_due(4)

    results = Reminders::Scheduler.new(tenant: @tenant, date: @date).dispatch_for(@tenant)

    assert_equal 0, results.sum(&:dispatched)
    assert_not MessageLog.exists?(invoice_id: invoice.id)
  end

  # MSG-006: 발송 시각 클램프·야간 이월(수동 발송 포함 — send_time_for 단일 기준)
  test "MSG-006 허용 시간대 호출은 당일 설정 시각 또는 즉시로 예약된다" do
    travel_to Time.zone.local(2026, 10, 20, 8, 0, 0) do
      assert_equal Time.zone.local(2026, 10, 20, 9, 0, 0),
                   Reminders::Scheduler.send_time_for(@tenant)
    end
    travel_to Time.zone.local(2026, 10, 20, 10, 30, 0) do
      assert_equal Time.zone.local(2026, 10, 20, 10, 30, 0),
                   Reminders::Scheduler.send_time_for(@tenant) # 허용 시간대 내면 즉시 발송
    end
  end

  test "MSG-006 야간 호출은 다일 설정 시각으로 이월된다" do
    travel_to Time.zone.local(2026, 10, 20, 22, 0, 0) do
      assert_equal Time.zone.local(2026, 10, 21, 9, 0, 0),
                   Reminders::Scheduler.send_time_for(@tenant)
    end
  end

  test "MSG-006 설정 시각이 범위 밖이면 9~17로 클램프된다" do
    @tenant.update_columns(remind_send_hour: 23) # DB 직접 — 검증 우회 시나리오
    travel_to Time.zone.local(2026, 10, 20, 22, 0, 0) do
      assert_equal 17, Reminders::Scheduler.send_time_for(@tenant).hour
    end
  end
end
