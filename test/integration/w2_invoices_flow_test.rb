# frozen_string_literal: true

require "test_helper"

# W2 HTTP 통합 테스트 — TEN-001 격리, 온보딩 게이트(W1 후속), INV-002/006,
# 취소 청구 재발송 차단(C4), 수신처 부재 SENT 방지(C5), 예약 파싱 실패(W10), MSG-007
class W2InvoicesFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @user = create_owner_user(name: "W2통합 학원")
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student)
    log_in(@user)
  end

  # TEN-001: 타 테넌트 청구 접근 차단(404)
  test "TEN-001 타 테넌트 청구는 조회·취소·재발송 모두 차단된다" do
    other_tenant, _other_user = create_owner_user(name: "타테넌트", phone_number: "01088887777")
    other_student = create_student_with_guardian(tenant: other_tenant, name: "타원생")
    other_invoice = create_invoice(other_tenant, other_student)

    get edit_invoice_path(other_invoice)
    assert_response :not_found
    post cancel_invoice_path(other_invoice), params: { cancel_reason: "x" }
    assert_response :not_found
    post resend_invoice_path(other_invoice)
    assert_response :not_found
  end

  # TEN-001: 타 테넌트 발송 이력(예약 취소 대상) 접근 차단
  test "TEN-001 타 테넌트 발송 이력의 예약 취소는 차단된다" do
    other_tenant, _other_user = create_owner_user(name: "타테넌트2", phone_number: "01077776666")
    other_student = create_student_with_guardian(tenant: other_tenant, name: "타원생2")
    other_invoice = create_invoice(other_tenant, other_student)
    other_log = other_invoice.message_logs.create!(tenant: other_tenant, student: other_student,
                                                   template_type: :invoice_notice, status: :QUEUED)

    delete invoice_message_log_path(other_log)
    assert_response :not_found
    assert other_log.reload.persisted? # 타 테넌트 로그는 삭제되지 않음
  end

  # W1 후속: 온보딩 미완료 테넌트의 메인 기능 직접 접근 차단
  test "온보딩 미완료 테넌트는 원생·청구·리마인더 접근이 차단된다" do
    gated_tenant, gated_user = create_owner_user(name: "게이트 학원", phone_number: "01066665555",
                                                 step: 2)
    open_session do |session|
      session.post session_url, params: { session: { phone_number: gated_user.phone_number,
                                                     password: "password123" } }
      [ students_path, invoices_path, reminders_path ].each do |path|
        session.get path
        session.assert_redirected_to onboarding_step_path(2)
      end
    end
    assert gated_tenant.reload.onboarding_step == 2
  end

  # INV-006/INV-002: 미리보기(확정) → READY 이후 조정은 사유 필수
  test "INV-002 READY 청구 수정은 사유 없이 422, 사유와 함께 성공한다" do
    @invoice.confirm!

    patch invoice_path(@invoice), params: { invoice: { adjustment_amount: "10000",
                                                       adjustment_note: "교재비" } }
    assert_response :unprocessable_entity

    patch invoice_path(@invoice), params: { invoice: { adjustment_amount: "10000",
                                                       adjustment_note: "교재비",
                                                       change_reason: "교재비 추가" } }
    assert_redirected_to invoices_path(month: @invoice.target_month)
    assert_equal 10_000, @invoice.reload.adjustment_amount
    assert_equal 1, @invoice.change_history_entries.size
  end

  # C5: 수신처 없는 청구는 즉시 발송해도 SENT로 변하지 않는다
  test "C5 수신처 없는 청구는 발송 후에도 READY로 남는다" do
    orphan = @tenant.students.create!(name: "보호자없는원생", monthly_fee: 90_000,
                                      payment_day: 25, status: :active)
    orphan_invoice = create_invoice(@tenant, orphan)
    @invoice.confirm!
    orphan_invoice.confirm!

    perform_enqueued_jobs do
      post send_batch_invoices_path, params: { month: @invoice.target_month,
                                               invoice_ids: [ @invoice.id, orphan_invoice.id ] }
    end

    assert_redirected_to results_invoices_path(month: @invoice.target_month)
    assert @invoice.reload.SENT?
    assert orphan_invoice.reload.READY?, "수신처 없는 청구가 SENT로 선반영되었다"
  end

  # W10: 예약 선택 + 무효 시각 → 즉시 발송으로 변질되지 않는다
  test "W10 예약 시각 파싱 실패 시 즉시 발송 변질이 차단된다" do
    @invoice.confirm!

    post send_batch_invoices_path, params: { month: @invoice.target_month,
                                             invoice_ids: [ @invoice.id ],
                                             scheduled: "1", send_at: "존재하지 않는 시각" }

    assert_redirected_to invoices_path(month: @invoice.target_month)
    assert @invoice.reload.READY?
    assert_equal 0, @invoice.message_logs.count
  end

  # C4: 취소된 청구의 '다시 보내기'는 차단된다
  test "C4 취소 청구의 재발송 요청은 차단된다" do
    @invoice.confirm!
    @invoice.cancel!("중복 발급")

    post resend_invoice_path(@invoice)

    assert_redirected_to results_invoices_path(month: @invoice.target_month)
    assert_equal 0, @invoice.message_logs.count # 새 발송 로그 없음
  end

  # MSG-007: 예약 발송 등록 → 대기열(QUEUED) → 취소 시 잡 미실행·로그 제거·READY 복귀
  test "MSG-007 예약 발송은 취소하면 실행되지 않는다" do
    @invoice.confirm!

    post send_batch_invoices_path, params: { month: @invoice.target_month,
                                             invoice_ids: [ @invoice.id ],
                                             scheduled: "1",
                                             send_at: 1.day.from_now.strftime("%Y-%m-%dT%H:%M") }
    assert_redirected_to results_invoices_path(month: @invoice.target_month)
    log = @invoice.message_logs.sole
    assert_equal "QUEUED", log.status
    assert @invoice.reload.READY? # 예약 중에는 SENT 아님

    perform_enqueued_jobs do
      delete invoice_message_log_path(log)
    end

    assert_redirected_to results_invoices_path(month: @invoice.target_month)
    assert_not MessageLog.exists?(log.id)
    assert @invoice.reload.READY?
  end
end
