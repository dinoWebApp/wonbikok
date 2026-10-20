require "test_helper"

class InvoicesFlowSmokeTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "스모크HTTP", practice: true, onboarding_step: 6)
    @user = @tenant.users.create!(phone_number: "01099998888", password: "password123")
    @student = @tenant.students.create!(name: "한원생", grade: "초2", monthly_fee: 180_000, payment_day: 5)
    @student.guardians.create!(name: "한어머님", phone_number: "01077776666", is_primary: true)
    @month = Date.current.strftime("%Y-%m")
    log_in_as(@user)
  end

  teardown do
    @tenant.destroy
  end

  test "청구 생성→확정→발송(연습) 흐름" do
    get invoices_path
    assert_response :success
    assert_match "이번 달 청구 만들기", response.body

    post invoices_path, params: { target_month: @month }
    assert_redirected_to invoices_path(month: @month)
    get invoices_path
    assert_match "한원생", response.body

    patch confirm_invoices_path, params: { month: @month }
    get invoices_path
    assert_match "발송 대기", response.body

    # 발송(연습 모드 — SIMULATED 기록, 큐 잡 인라인 실행)
    invoice = @tenant.invoices.first
    perform_enqueued_jobs do
      post send_batch_invoices_path, params: { month: @month, invoice_ids: [ invoice.id ] }
    end
    assert_redirected_to results_invoices_path(month: @month)
    get results_invoices_path, params: { month: @month }
    assert_match "시뮬레이션", response.body

    get invoices_path
    assert_match "발송 완료", response.body # Invoice SENT 배지
  end

  test "청구 취소는 사유 필수이며 CANCELLED로 전이된다" do
    @tenant.invoices.create!(student: @student, target_month: @month,
                             student_name_snapshot: @student.name, base_amount: @student.monthly_fee,
                             due_on: Date.current)
    invoice = @tenant.invoices.first

    post cancel_invoice_path(invoice), params: { cancel_reason: "테스트 취소" }
    assert_redirected_to invoices_path(month: @month)
    assert invoice.reload.CANCELLED?
    assert_equal "테스트 취소", invoice.cancel_reason

    get invoices_path
    assert_match "취소", response.body
  end

  test "취소 사유 폼과 조정 폼이 렌더된다" do
    @tenant.invoices.create!(student: @student, target_month: @month,
                             student_name_snapshot: @student.name, base_amount: @student.monthly_fee,
                             due_on: Date.current)
    get cancel_invoice_path(@tenant.invoices.first)
    assert_response :success
    assert_match "취소 사유", response.body

    get edit_invoice_path(@tenant.invoices.first)
    assert_response :success
    assert_match "조정액", response.body
  end

  private

  def log_in_as(user)
    post session_url, params: { session: { phone_number: "01099998888", password: "password123" } }
    assert_redirected_to root_path
  end
end
