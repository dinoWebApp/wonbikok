# frozen_string_literal: true

require "test_helper"

# 입금 확인 컨트롤러 테스트 — 인증, TEN-001(테넌트 격리·타 테넌트 404),
# F4 플로우(리스트→등록→취소), PAY-001/002, CR-002 트리거(origin:auto 1회·부분납 미호출).
# Triggerable은 singleton 스파이로 대체 — 외부 실호출 없음.
# 주의: payments.* i18n 키는 3-S에서 ko.yml에 추가되므로 정적 문구 단정은 하지 않는다(DB 파생 텍스트만 단정).
class PaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @user = create_owner_user
    @other_tenant, @other_user = create_owner_user(name: "다른 학원", phone_number: "01088887777")
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT) # 250_000
  end

  def stub_trigger(outcome: :created)
    original = CashReceipt::Triggerable.method(:trigger_issue_for)
    calls = []
    CashReceipt::Triggerable.define_singleton_method(:trigger_issue_for) do |invoice, issued_by:, origin:|
      calls << { invoice_id: invoice.id, issued_by: issued_by, origin: origin }
      CashReceipt::Triggerable::Result.new(receipt: nil, outcome: outcome)
    end
    yield calls
  ensure
    CashReceipt::Triggerable.define_singleton_method(:trigger_issue_for, original)
  end

  def create_active_payment(invoice, amount:)
    Payment.create!(tenant: invoice.tenant, invoice: invoice, status: :active,
                    amount: amount, paid_on: Date.current, method: "transfer",
                    confirmed_by: "01033334444", confirmed_at: Time.current)
  end

  test "비로그인 접근은 로그인으로 리다이렉트된다" do
    get payments_path

    assert_redirected_to new_session_path
  end

  test "미확인 리스트 — 잔액 표시, 타 테넌트 청구 미노출(TEN-001)" do
    other_student = create_student_with_guardian(tenant: @other_tenant, name: "외부원생")
    create_invoice(@other_tenant, other_student, status: :SENT)
    create_active_payment(@invoice, amount: 100_000)
    @invoice.update!(status: :PARTIALLY_PAID)

    log_in(@user)
    get payments_path

    assert_response :ok
    assert_match(/김민준/, @response.body) # 자기 테넌트 미확인 건
    assert_match(/150,000/, @response.body) # 잔액(250,000-100,000)
    assert_no_match(/외부원생/, @response.body) # TEN-001
  end

  # PAY-002(C1) — 완납(PAID) 건은 미확인 리스트에 없으므로 수납 이력 섹션에서
  # 수납 행 + 오체크 취소 진입을 제공한다(취소 UI 도달 가능 보장).
  test "수납 이력 섹션 — 완납 건 수납 행과 취소 진입 링크를 표시한다" do
    paid_invoice = create_invoice(@tenant, @student, status: :SENT, target_month: "2026-09")
    payment = create_active_payment(paid_invoice, amount: 250_000)
    paid_invoice.update!(status: :PAID)

    log_in(@user)
    get payments_path, params: { month: "2026-09" }

    assert_response :ok
    assert_match(/김민준/, @response.body)                        # 이력 행(원생명)
    assert_match(/250,000/, @response.body)                      # 수납 금액
    assert_match(/010-\*\*\*\*-4444/, @response.body)            # 처리자 마스킹 표시(TEN-003)
    assert_match(cancel_payment_path(payment), @response.body)   # 오체크 취소 진입

    # 월 스코프 — 다른 월의 수납 이력은 노출하지 않는다
    get payments_path, params: { month: Date.current.strftime("%Y-%m") }
    assert_no_match(cancel_payment_path(payment), @response.body)
  end

  # PAY-002(C1) — 부분납 카드에도 등록 수납의 취소 진입을 제공한다.
  test "부분납 카드 — 수납 내역 접기와 취소 진입 링크를 표시한다" do
    payment = create_active_payment(@invoice, amount: 100_000)
    @invoice.update!(status: :PARTIALLY_PAID)

    log_in(@user)
    get payments_path

    assert_response :ok
    assert_match(cancel_payment_path(payment), @response.body)
  end

  test "새 입금 등록 — 금액 힌트 후보를 표시한다(PAY-003)" do
    log_in(@user)
    get new_payment_path, params: { hint_amount: "250000" }

    assert_response :ok
    assert_match(/김민준/, @response.body) # 후보는 DB 파생 텍스트(원생명)만 단정
  end

  test "TEN-001 타 테넌트 수납 취소 폼은 404" do
    other_invoice = create_invoice(@other_tenant,
                                   create_student_with_guardian(tenant: @other_tenant), status: :SENT)
    other_payment = create_active_payment(other_invoice, amount: 250_000)

    log_in(@user)
    get cancel_payment_path(other_payment)

    assert_response :not_found
  end

  test "입금 확인(체크) — 전액 등록 시 PAID 전이 + origin:auto 트리거 1회(CR-002)" do
    stub_trigger do |calls|
      log_in(@user)

      assert_difference -> { Payment.active.count }, 1 do
        post payments_path, params: { payment: { invoice_id: @invoice.id, amount: "250000",
                                                 paid_on: Date.current.to_s, method: "transfer" } }
      end

      assert_redirected_to payments_path(month: @invoice.target_month)
      assert_equal 1, calls.size
      assert_equal :auto, calls.first[:origin]
      assert @invoice.reload.PAID?
    end
  end

  test "부분납 등록 — PARTIALLY_PAID 전이, 자동발행 트리거 없음(CR-002 부분납 보류)" do
    stub_trigger do |calls|
      log_in(@user)
      post payments_path, params: { payment: { invoice_id: @invoice.id, amount: "100000",
                                               paid_on: Date.current.to_s, method: "transfer",
                                               memo: "일부 입금" } }

      assert_redirected_to payments_path(month: @invoice.target_month)
      assert @invoice.reload.PARTIALLY_PAID?
      assert_empty calls
    end
  end

  test "PAY-001 완납 청구의 재등록은 422로 거절된다" do
    create_active_payment(@invoice, amount: 250_000)
    @invoice.update!(status: :PAID)

    stub_trigger do |calls|
      log_in(@user)
      post payments_path, params: { payment: { invoice_id: @invoice.id, amount: "10000",
                                               paid_on: Date.current.to_s, method: "transfer" } }

      assert_response :unprocessable_entity
      assert_empty calls
    end
  end

  test "TEN-001 타 테넌트 청구로의 등록은 거절된다" do
    other_invoice = create_invoice(@other_tenant,
                                   create_student_with_guardian(tenant: @other_tenant), status: :SENT)

    stub_trigger do |calls|
      log_in(@user)
      post payments_path, params: { payment: { invoice_id: other_invoice.id, amount: "250000",
                                               paid_on: Date.current.to_s, method: "transfer" } }

      assert_response :unprocessable_entity
      assert_empty calls
      assert_equal 0, Payment.count
    end
  end

  test "PAY-002 오체크 취소 — 사유 없이는 422, 사유와 함께 이력 전이 + UNPAID 복원" do
    payment = create_active_payment(@invoice, amount: 100_000)
    @invoice.update!(status: :PARTIALLY_PAID)

    log_in(@user)
    post cancel_payment_payment_path(payment), params: { cancel_reason: "" }
    assert_response :unprocessable_entity

    assert_difference -> { Payment.active.count }, -1 do
      post cancel_payment_payment_path(payment), params: { cancel_reason: "오체크" }
    end

    assert_redirected_to payments_path(month: @invoice.target_month)
    assert payment.reload.cancelled?
    assert_equal "오체크", payment.cancel_reason
    assert @invoice.reload.UNPAID?
  end

  test "취소 폼 — 대상 수납 정보 표시" do
    payment = create_active_payment(@invoice, amount: 250_000)

    log_in(@user)
    get cancel_payment_path(payment)

    assert_response :ok
    assert_match(/김민준/, @response.body)
    assert_match(/250,000/, @response.body)
  end

  # PAY-002(C1) 완납 건 오체크 취소 E2E — PAID → UNPAID 복원(due_on 미경과), 미확인 리스트 복귀.
  # 이미 발행된 현금영수증은 자동 취소되지 않고(잔존) 취소 화면 안내로 수동 취소 경로(CR-005)를 유도한다.
  test "PAY-002 완납 건 오체크 취소 — UNPAID 복원, 미확인 리스트 복귀, 영수증은 잔존한다" do
    stub_trigger do |calls|
      log_in(@user)

      # 전액 확인 → PAID 전이 + 자동발행 트리거 1회(CR-002)
      post payments_path, params: { payment: { invoice_id: @invoice.id, amount: "250000",
                                               paid_on: Date.current.to_s, method: "transfer" } }
      assert_redirected_to payments_path(month: @invoice.target_month)
      assert @invoice.reload.PAID?
      payment = Payment.active.find_by!(invoice_id: @invoice.id)
      assert_equal 1, calls.size

      # 완납 건은 미확인 리스트에서 사라지고 수납 이력 섹션의 취소 진입만 노출된다(C1)
      get payments_path
      assert_response :ok
      assert_no_match(new_payment_path(invoice_id: @invoice.id), @response.body)
      assert_match(cancel_payment_path(payment), @response.body)

      # 잔존 영수증 모사 — 취소 화면 안내가 수동 취소 경로를 유도한다
      CashReceipt.create!(tenant: @tenant, invoice: @invoice,
                          mgt_key: CashReceipt.build_mgt_key(@invoice, :income_deduction),
                          issue_type: :income_deduction, state: :issued, amount: 250_000,
                          item_name: "#{@invoice.target_month} 원비", trade_date: Time.current,
                          issued_by: "01033334444")
      get cancel_payment_path(payment)
      assert_response :ok
      assert_match(/발행 이력 화면에서 별도 취소/, @response.body) # payments.cancel.notice

      # 오체크 취소 → UNPAID 복원(due_on=오늘), 영수증은 자동 취소되지 않는다
      assert_no_difference -> { CashReceipt.count } do
        post cancel_payment_payment_path(payment), params: { cancel_reason: "오체크" }
      end
      assert_redirected_to payments_path(month: @invoice.target_month)
      assert @invoice.reload.UNPAID?
      assert payment.reload.cancelled?
      assert_equal "issued", CashReceipt.find_by!(invoice_id: @invoice.id).state # 영수증 잔존

      # 미확인 리스트로 복귀 — 등록 진입은 다시 노출, 취소 이력 행은 재노출되지 않는다
      get payments_path
      assert_match(new_payment_path(invoice_id: @invoice.id), @response.body)
      assert_no_match(cancel_payment_path(payment), @response.body)
      assert_equal 1, calls.size # 취소는 자동발행 트리거를 호출하지 않는다(CR-002)
    end
  end

  # PAY-002 — 기한 경과 완납 건의 오체크 취소는 due_on 기준 OVERDUE로 복원되고 리스트로 복귀한다.
  test "PAY-002 기한 경과 완납 건의 오체크 취소는 OVERDUE로 복원되고 리스트로 복귀한다" do
    stub_trigger do |_calls|
      @invoice.update!(due_on: Date.current - 3.days)
      log_in(@user)
      post payments_path, params: { payment: { invoice_id: @invoice.id, amount: "250000",
                                               paid_on: Date.current.to_s, method: "transfer" } }
      assert @invoice.reload.PAID?
      payment = Payment.active.find_by!(invoice_id: @invoice.id)

      post cancel_payment_payment_path(payment), params: { cancel_reason: "오체크" }

      assert_redirected_to payments_path(month: @invoice.target_month)
      assert @invoice.reload.OVERDUE? # due_on 경과 — 재계산 복원
      get payments_path
      assert_response :ok
      assert_match(new_payment_path(invoice_id: @invoice.id), @response.body)
    end
  end

  # CR-002 — 부분납(PARTIALLY_PAID)은 트리거를 보류하고, 추가 수납으로 완납 전이하는
  # 그 시점에 origin:auto 1회만 호출된다.
  test "부분납 후 추가 수납으로 완납 전이 시 그 시점에 트리거가 1회 호출된다(CR-002)" do
    stub_trigger do |calls|
      log_in(@user)
      post payments_path, params: { payment: { invoice_id: @invoice.id, amount: "100000",
                                               paid_on: Date.current.to_s, method: "transfer" } }
      assert_redirected_to payments_path(month: @invoice.target_month)
      assert @invoice.reload.PARTIALLY_PAID?
      assert_empty calls # 부분납 시점 — 자동발행 보류(PRD 14장 확정)

      post payments_path, params: { payment: { invoice_id: @invoice.id, amount: "150000",
                                               paid_on: Date.current.to_s, method: "transfer" } }
      assert_redirected_to payments_path(month: @invoice.target_month)
      assert @invoice.reload.PAID?
      assert_equal 1, calls.size # 완납 전이 시점 1회
      assert_equal :auto, calls.first[:origin]
      assert_equal @invoice.id, calls.first[:invoice_id]
    end
  end
end
