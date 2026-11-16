require "test_helper"

class CashReceiptTest < ActiveSupport::TestCase
  setup do
    @tenant, = create_owner_user
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT)
  end

  def build_receipt(**attrs)
    CashReceipt.new({
      tenant: @tenant,
      invoice: @invoice,
      mgt_key: CashReceipt.build_mgt_key(@invoice, :income_deduction),
      issue_type: :income_deduction,
      state: :pending,
      amount: @invoice.total_amount,
      trade_date: Time.current,
      identity_num: "01011112222"
    }.merge(attrs))
  end

  test "CR-001 mgt_key 파생 규칙 — invoice·월·발급유형 포함 24자 이내" do
    key = CashReceipt.build_mgt_key(@invoice, :income_deduction)
    assert_match(/\ACR#{@invoice.id}\d{6}ID\z/, key)
    assert key.length <= 24
    assert_equal "CRC#{key}", build_receipt(mgt_key: key).build_cancel_mgt_key
  end

  test "CR-001 mgt_key 중복은 검증으로 거절된다" do
    build_receipt.save!
    duplicate = build_receipt(amount: 1)

    assert_not duplicate.valid?
    assert duplicate.errors[:mgt_key].present?
  end

  test "CR-001 DB 유니크 인덱스가 동시 생성을 차단한다" do
    build_receipt.save!
    duplicate = build_receipt(amount: 1)

    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save(validate: false) # 검증 우회 INSERT — DB 유니크 제약 직접 확인
    end
  end

  test "CR-003 processing 이외 상태에서 issued 전이는 거절된다" do
    receipt = build_receipt
    receipt.save!

    assert_not receipt.mark_issued!(nts_confirm_num: "123456789")
    assert receipt.pending?

    receipt.update!(state: :processing)
    assert receipt.mark_issued!(nts_confirm_num: "123456789")
    assert receipt.issued?
    assert_equal 3000, receipt.barobill_state
    assert receipt.issued_at.present?
  end

  test "TradeDate D-1 제약 — 어제보다 과거 거래일자는 생성 시 거절된다(W1: 항상 적용)" do
    receipt = build_receipt(trade_date: 2.days.ago)

    assert_not receipt.valid?
    assert receipt.errors[:trade_date].present?
    assert build_receipt.valid? # 트리거 시점 일시라 통과
  end

  test "C4(TEN-003) issued_by 휴대폰번호는 마스킹 저장 — 원문 없음" do
    receipt = build_receipt(issued_by: "01011112222")
    receipt.save!

    assert_equal "010-****-2222", receipt.issued_by
    raw = CashReceipt.connection.select_value(
      "SELECT issued_by FROM cash_receipts WHERE id = #{receipt.id}"
    )
    assert_not_includes raw.to_s, "01011112222"
  end

  test "TEN-002 주민등록번호 형태(13자리 숫자) 식별번호는 거절된다" do
    receipt = build_receipt(identity_num: "9001011234567")

    assert_not receipt.valid?
    assert receipt.errors[:identity_num].present?
  end

  test "TEN-003 identity_num은 암호문으로 저장되고 마스킹 표시된다" do
    receipt = build_receipt
    receipt.save!

    ciphertext = CashReceipt.connection.select_value(
      "SELECT identity_num FROM cash_receipts WHERE id = #{receipt.id}"
    )
    assert_not_equal "01011112222", ciphertext
    assert_equal "01011112222", receipt.reload.identity_num # 복호화 검증
    assert_equal "********2222", receipt.masked_identity_num
  end

  test "소득공제용 수취인은 대표 보호자 휴대폰번호로 확정된다" do
    receipt = build_receipt(state: :needs_info)
    receipt.save!

    receipt.resolve_identity_num!
    assert receipt.pending?
    assert_equal "01011112222", receipt.identity_num
  end

  test "지급증명용 수취인은 보호자 사업자번호 — 미비 시 needs_info" do
    receipt = build_receipt(issue_type: :expense_evidence, state: :pending, identity_num: nil)
    receipt.save!

    receipt.resolve_identity_num!
    assert receipt.needs_info?

    @student.primary_guardian.update!(business_number: "1234567890")
    receipt.resolve_identity_num!
    assert receipt.pending?
    assert_equal "1234567890", receipt.identity_num
  end

  test "retryable은 failed만, cancellable은 issued만 허용한다" do
    assert build_receipt(state: :pending).retryable? == false
    assert build_receipt(state: :failed).retryable?
    assert build_receipt(state: :processing).cancellable? == false
    assert build_receipt(state: :issued, nts_confirm_num: "123456789").cancellable?
  end
end
