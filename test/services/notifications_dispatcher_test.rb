# frozen_string_literal: true

# 발송 오케스트레이션 테스트 — MSG-001/002 사전단계, MSG-007, 수신처 부재(C5)
class NotificationsDispatcherTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(name: "디스패처 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student)
    @invoice.confirm!
  end

  # 정상: 발송 큐 등록 — QUEUED 로그 1건 + 예약 잡
  test "dispatch는 QUEUED 로그와 잡을 등록한다" do
    result = Notifications::Dispatcher.new(tenant: @tenant).dispatch(Invoice.where(id: @invoice.id))

    assert_equal 1, result.queued
    log = @invoice.message_logs.sole
    assert_equal "QUEUED", log.status
    assert_equal "invoice_notice", log.template_type
    assert log.job_id.present?
  end

  # MSG-001: 동일 [invoice, template_type] 재발송(재발송 플래그 없음) → duplicated 집계
  test "MSG-001 중복 dispatch는 duplicated로 집계된다" do
    dispatcher = Notifications::Dispatcher.new(tenant: @tenant)
    dispatcher.dispatch(Invoice.where(id: @invoice.id))

    assert_no_enqueued_jobs do
      result = dispatcher.dispatch(Invoice.where(id: @invoice.id))
      assert_equal 0, result.queued
      assert_equal 1, result.duplicated
    end
    assert_equal 1, @invoice.message_logs.count
  end

  # MSG-001: 동시 삽입 경쟁(RecordNotUnique)도 duplicated로 흡수(C1 회귀)
  test "MSG-001 검증 우회 선점 건에 대한 dispatch는 RecordNotUnique를 duplicated로 흡수한다" do
    MessageLog.insert_all!([ {
      tenant_id: @tenant.id, invoice_id: @invoice.id, student_id: @student.id,
      template_type: "invoice_notice", status: "QUEUED", channel: "alimtalk"
    } ])

    result = Notifications::Dispatcher.new(tenant: @tenant).dispatch(Invoice.where(id: @invoice.id))

    assert_equal 0, result.queued
    assert_equal 1, result.duplicated
  end

  # MSG-001: resend_of 설정 시 재발송 허용 + 이력 연결
  test "MSG-001 재발송(resend_of)은 유일성 예외로 큐에 등록된다" do
    dispatcher = Notifications::Dispatcher.new(tenant: @tenant)
    dispatcher.dispatch(Invoice.where(id: @invoice.id))
    original = @invoice.message_logs.QUEUED.first

    result = dispatcher.dispatch(Invoice.where(id: @invoice.id), resend: original)

    assert_equal 1, result.queued
    resend = @invoice.message_logs.order(:created_at).last
    assert_equal original.id, resend.resend_of_id
    assert_equal 1, original.reload.resends.count
  end

  # C5: 수신처 없는 청구는 큐 등록·SENT 후보에서 제외
  test "수신처 없는 청구는 recipients_missing으로 집계되고 큐에 등록되지 않는다" do
    orphan_student = @tenant.students.create!(name: "보호자없는원생", monthly_fee: 100_000,
                                              payment_day: 25, status: :active)
    orphan_invoice = create_invoice(@tenant, orphan_student)
    orphan_invoice.confirm!

    result = Notifications::Dispatcher.new(tenant: @tenant)
                                      .dispatch(Invoice.where(id: [ @invoice.id, orphan_invoice.id ]))

    assert_equal 1, result.queued
    assert_equal 1, result.recipients_missing
    assert_equal [ @invoice.id ], result.dispatched_invoice_ids
    assert_not MessageLog.exists?(invoice_id: orphan_invoice.id)
  end

  # MSG-007: 예약 발송 취소 — 잡 discard + 로그 제거 + 청구 READY 복귀
  test "MSG-007 QUEUED 예약 건은 취소되고 로그가 제거된다" do
    dispatcher = Notifications::Dispatcher.new(tenant: @tenant)
    dispatcher.dispatch(Invoice.where(id: @invoice.id), send_at: 1.day.from_now)
    log = @invoice.message_logs.sole
    assert log.QUEUED?

    assert dispatcher.cancel_scheduled(log)
    assert log.destroyed?
    assert @invoice.reload.READY?
  end

  # MSG-007: QUEUED가 아니면 취소 불가(거짓 취소 방지)
  test "MSG-007 QUEUED가 아닌 로그는 취소되지 않는다" do
    log = @invoice.message_logs.create!(tenant: @tenant, student: @student,
                                        template_type: :invoice_notice, status: :SENT)

    assert_not Notifications::Dispatcher.new(tenant: @tenant).cancel_scheduled(log)
    assert log.reload.persisted?
  end

  # INV-003: 취소 청구는 dispatch 대상에서 사전 필터(스케줄러와 동일 전제 — sendable/remindable 확인)
  test "INV-003 취소 청구는 sendable 스코프에서 제외된다" do
    @invoice.cancel!("중복 발급")

    assert_not_includes Invoice.sendable, @invoice.reload
  end
end
