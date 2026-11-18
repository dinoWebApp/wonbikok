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

  # W3 F4/F9 결선 — 청구 목록의 입금 확인 진입·청구 링크 관리(발급/복사/재발급/폐기)
  test "청구 목록에서 입금 확인 진입과 청구 링크 발급·재발급·폐기가 동작한다" do
    invoice = @tenant.invoices.create!(student: @student, target_month: @month,
                                       student_name_snapshot: @student.name, base_amount: @student.monthly_fee,
                                       due_on: Date.current, status: :READY)

    # F4 진입 — 미완납 확정 청구에 입금 확인 버튼
    get invoices_path(month: @month)
    assert_response :success
    assert_match "입금 확인", response.body
    assert_match new_payment_path(invoice_id: invoice.id), response.body

    # F9 발급(멱등) — 유효 토큰 보유 시 복사·재발급·폐기 열 노출
    post issue_link_invoice_path(invoice)
    assert_redirected_to invoices_path(month: @month)
    token = invoice.reload.public_token
    assert_not_nil token

    get invoices_path(month: @month)
    assert_match "링크 복사", response.body
    assert_match "재발급", response.body
    assert_match "링크 폐기", response.body

    # 재발급 — 이전 토큰 즉시 만료(LNK-003)
    post issue_link_invoice_path(invoice, params: { reissue: "1" })
    assert_redirected_to invoices_path(month: @month)
    new_token = invoice.reload.public_token
    assert_not_equal token, new_token
    get billing_link_path(token)
    assert_response :not_found
    get billing_link_path(new_token)
    assert_response :ok

    # 폐기 — 이후 목록에는 발급 버튼으로 복귀
    post revoke_link_invoice_path(invoice)
    assert_redirected_to invoices_path(month: @month)
    get invoices_path(month: @month)
    assert_match "링크 발급", response.body
  end

  # LNK-003/INV-003 — CANCELLED 청구 링크 발급 직접 POST 거부(뷰 버튼 숨김만으로는 부족)
  test "취소된 청구의 링크 발급 직접 POST는 거부되고 토큰이 발급되지 않는다" do
    invoice = @tenant.invoices.create!(student: @student, target_month: @month,
                                       student_name_snapshot: @student.name, base_amount: @student.monthly_fee,
                                       due_on: Date.current, status: :READY)
    assert invoice.cancel!("테스트 취소")

    post issue_link_invoice_path(invoice)

    assert_redirected_to invoices_path(month: @month)
    assert_equal "취소된 청구에는 청구 링크를 발급할 수 없습니다.", flash[:alert]
    assert_nil invoice.reload.public_token

    post issue_link_invoice_path(invoice, params: { reissue: "1" })

    assert_redirected_to invoices_path(month: @month)
    assert_equal "취소된 청구에는 청구 링크를 발급할 수 없습니다.", flash[:alert]
    assert_nil invoice.reload.public_token
  end

  private

  def log_in_as(user)
    post session_url, params: { session: { phone_number: "01099998888", password: "password123" } }
    assert_redirected_to dashboard_path # 2026-11-04: 루트가 랜딩으로 이동 — 로그인 후 앱 홈은 /dashboard
  end
end
