require "test_helper"

class CashReceiptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @user = create_owner_user
    @other_tenant, @other_user = create_owner_user(name: "다른 학원", phone_number: "01088887777")
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT)
  end

  def create_receipt(state: :pending, invoice: @invoice, issue_type: :income_deduction)
    invoice.tenant.cash_receipts.create!(
      tenant: invoice.tenant, invoice: invoice,
      mgt_key: CashReceipt.build_mgt_key(invoice, issue_type),
      issue_type: issue_type, state: state,
      amount: invoice.total_amount, trade_date: Time.current, identity_num: "01011112222"
    )
  end

  test "목록 — 당월 필터 기본, 발행 이력 표시(TEN-001 타 테넌트 이력 미노출)" do
    create_receipt
    other_student = create_student_with_guardian(tenant: @other_tenant, name: "외부원생")
    create_receipt(state: :issued,
                   invoice: create_invoice(@other_tenant, other_student, status: :SENT))

    log_in(@user)
    get cash_receipts_path

    assert_response :ok
    assert_match(/김민준/, @response.body) # 자기 테넌트 이력 표시
    assert_no_match(/외부원생/, @response.body) # TEN-001: 타 테넌트 이력 미노출
  end

  test "TEN-001 타 테넌트 영수증 상세는 404" do
    other_receipt = create_receipt(invoice: create_invoice(@other_tenant,
                                                           create_student_with_guardian(tenant: @other_tenant), status: :SENT))

    log_in(@user)
    get cash_receipt_path(other_receipt)

    assert_response :not_found
  end

  test "수동 발행 — 트리거 경유 생성 + 상세 리다이렉트" do
    log_in(@user)

    assert_difference -> { CashReceipt.count }, 1 do
      post issue_cash_receipts_path, params: { invoice_id: @invoice.id }
    end

    assert_redirected_to cash_receipt_path(CashReceipt.last)
  end

  test "수동 발행 중복 — 기존 건 상세로 안내(CR-001 멱등)" do
    receipt = create_receipt
    log_in(@user)

    assert_no_difference -> { CashReceipt.count } do
      post issue_cash_receipts_path, params: { invoice_id: @invoice.id }
    end

    assert_redirected_to cash_receipt_path(receipt)
  end

  test "수동 재발행은 failed 상태만 허용" do
    failed = create_receipt(state: :failed)
    processing = create_receipt(state: :processing, issue_type: :expense_evidence)
    log_in(@user)

    post retry_cash_receipt_path(failed)
    assert_redirected_to cash_receipt_path(failed)
    assert_equal "pending", failed.reload.state
    assert_equal 1, failed.retry_count

    post retry_cash_receipt_path(processing)
    assert_redirected_to cash_receipt_path(processing)
    assert_equal "processing", processing.reload.state # 상태 유지
  end

  test "취소 — 사유 없이 제출하면 422 재렌더(CR-005 사유 필수)" do
    issued = create_receipt(state: :issued, invoice: @invoice)
    issued.update!(nts_confirm_num: "123456789")
    log_in(@user)

    post cancel_cash_receipt_path(issued), params: { cancel_reason: "  " }

    assert_response :unprocessable_entity
    assert_equal "issued", issued.reload.state
  end

  test "취소 — 사유와 함께 요청하면 cancel_pending 전이·취소 이력 기록" do
    issued = create_receipt(state: :issued, invoice: @invoice)
    issued.update!(nts_confirm_num: "123456789")
    log_in(@user)

    # SIMULATED 모드(테스트 환경 — cert_key 공백)이므로 즉시 cancelled 확정
    post cancel_cash_receipt_path(issued), params: { cancel_reason: "오발행 정정" }

    assert_redirected_to cash_receipt_path(issued)
    assert_equal "cancelled", issued.reload.state
    assert_equal "오발행 정정", issued.cancel_reason
    assert_equal "CRC#{issued.mgt_key}", issued.cancel_mgt_key
    assert issued.cancelled_at.present?
  end

  test "취소 폼 — issued 상태만 진입 가능" do
    issued = create_receipt(state: :issued, invoice: @invoice)
    pending_receipt = create_receipt(issue_type: :expense_evidence)
    log_in(@user)

    get cancel_cash_receipt_path(issued)
    assert_response :ok

    get cancel_cash_receipt_path(pending_receipt)
    assert_redirected_to cash_receipt_path(pending_receipt)
  end

  test "C2 취소 중 바로빌 네트워크 오류 — issued 복원·last_error 기록(500 아님)" do
    issued = create_receipt(state: :issued, invoice: @invoice)
    issued.update!(nts_confirm_num: "123456789")
    log_in(@user)

    stub_barobill_service(
      Class.new do
        def cancel(...) = raise Barobill::Error.new("NETWORK_ERROR: Net::ReadTimeout", code: :network_error)
      end.new
    ) do
      post cancel_cash_receipt_path(issued), params: { cancel_reason: "오발행 정정" }
    end

    assert_response :unprocessable_entity
    assert_equal "issued", issued.reload.state # cancel_pending 고착 없음 — 원본 상태 복원
    assert issued.last_error.present?
  end

  test "B2 연습 모드 테넌트 취소 — cert_key가 있어도 SIMULATED 강제(네트워크 0회)" do
    @tenant.update!(practice: true)
    issued = create_receipt(state: :issued, invoice: @invoice)
    issued.update!(nts_confirm_num: "123456789")
    log_in(@user)

    stub_resolve_cert_key("fake-release-key") do
      forbid_network do
        post cancel_cash_receipt_path(issued), params: { cancel_reason: "오발행 정정" }
      end
    end

    assert_redirected_to cash_receipt_path(issued)
    assert_equal "cancelled", issued.reload.state # SIMULATED — 즉시 취소 확정
  end

  test "C4 수동 발행 처리자 기록 — 휴대폰번호 원문 없이 마스킹 저장" do
    log_in(@user)

    post issue_cash_receipts_path, params: { invoice_id: @invoice.id }
    receipt = CashReceipt.last

    assert_equal "010-****-4444", receipt.issued_by
    raw = CashReceipt.connection.select_value(
      "SELECT issued_by FROM cash_receipts WHERE id = #{receipt.id}"
    )
    assert_not_includes raw.to_s, @user.phone_number
  end

  test "C5 과거 월 이력 조회 — YYYY-MM 형식 파라미터 수용, 무효 값은 당월 기본" do
    past_student = create_student_with_guardian(tenant: @tenant, name: "과거원생")
    past_invoice = create_invoice(@tenant, past_student, status: :SENT, target_month: "2026-09")
    create_receipt(state: :issued, invoice: past_invoice)
    log_in(@user)

    get cash_receipts_path(month: "2026-09")
    assert_response :ok
    assert_match(/과거원생/, @response.body)

    get cash_receipts_path(month: "2026-13; DROP") # 무효 형식 — 당월 기본
    assert_response :ok
    assert_no_match(/과거원생/, @response.body)
  end

  test "C6 needs_info 보완 후 재발행 — 식별번호 재확정 후 IssueJob 재큐" do
    @student.primary_guardian.update!(business_number: "1234567890")
    needs_info = create_receipt(issue_type: :expense_evidence, state: :needs_info)
    log_in(@user)

    assert_enqueued_with job: CashReceipt::IssueJob do
      post retry_cash_receipt_path(needs_info)
    end
    assert_redirected_to cash_receipt_path(needs_info)
    assert_equal "pending", needs_info.reload.state
    assert_equal "1234567890", needs_info.identity_num
  end

  test "C6 needs_info 미보완 재시도 — 상태 유지·큐 진입 없음" do
    needs_info = create_receipt(issue_type: :expense_evidence, state: :needs_info)
    log_in(@user)

    assert_no_enqueued_jobs only: CashReceipt::IssueJob do
      post retry_cash_receipt_path(needs_info)
    end
    assert_redirected_to cash_receipt_path(needs_info)
    assert_equal "needs_info", needs_info.reload.state
  end

  private

  def stub_resolve_cert_key(key)
    Barobill::BaseService.singleton_class.class_eval do
      alias_method :original_resolve_cert_key, :resolve_cert_key
      define_method(:resolve_cert_key) { key }
    end
    yield
  ensure
    Barobill::BaseService.singleton_class.class_eval do
      alias_method :resolve_cert_key, :original_resolve_cert_key
      remove_method :original_resolve_cert_key
    end
  end

  def forbid_network
    Barobill::BaseService.class_eval do
      alias_method :original_post_xml, :post_xml
      define_method(:post_xml) { |*| raise "네트워크 호출 금지 — SIMULATED 강제 위반" }
    end
    yield
  ensure
    Barobill::BaseService.class_eval do
      alias_method :post_xml, :original_post_xml
      remove_method :original_post_xml
    end
  end

  def stub_barobill_service(instance)
    Barobill::CashReceiptService.singleton_class.class_eval do
      alias_method :original_from_credentials_with_tenant, :from_credentials_with_tenant
      define_method(:from_credentials_with_tenant) { |_| instance }
    end
    yield
  ensure
    Barobill::CashReceiptService.singleton_class.class_eval do
      alias_method :from_credentials_with_tenant, :original_from_credentials_with_tenant
      remove_method :original_from_credentials_with_tenant
    end
  end
end
