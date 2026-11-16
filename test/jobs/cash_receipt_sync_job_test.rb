require "test_helper"

class CashReceiptSyncJobTest < ActiveJob::TestCase
  setup do
    @tenant, = create_owner_user
    @tenant.update!(barobill_member_id: "wonbi1")
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT)
    @receipt = CashReceipt.create!(
      tenant: @tenant, invoice: @invoice,
      mgt_key: CashReceipt.build_mgt_key(@invoice, :income_deduction),
      issue_type: :income_deduction, state: :processing,
      amount: @invoice.total_amount, trade_date: Time.current, identity_num: "01011112222"
    )
  end

  ServiceStub = Data.define(:state_response) do
    def state(mgt_key:) = state_response
  end

  def state_ok(state, confirm_num: nil)
    Barobill::BaseService::Result.ok(
      value: { barobill_state: state, nts_confirm_num: confirm_num, nts_confirm_message: confirm_num ? nil : "사유" }
    )
  end

  def with_service(result)
    stub_service_builder(ServiceStub.new(result)) { yield }
  end

  def stub_service_builder(instance)
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

  test "3000(전송 완료) — issued 확정 + 학부모 발행 안내 1회(CR-003)" do
    with_service(state_ok(3000, confirm_num: "123456789")) do
      assert_difference -> { MessageLog.cash_receipt_issued.count }, 1 do
        CashReceipt::SyncJob.perform_now(@receipt.id)
      end
    end

    @receipt.reload
    assert @receipt.issued?
    assert_equal "123456789", @receipt.nts_confirm_num
    assert_equal 3000, @receipt.barobill_state
  end

  test "4000(전송 실패) — failed 확정 + 사유 기록" do
    with_service(state_ok(4000)) do
      CashReceipt::SyncJob.perform_now(@receipt.id)
    end

    assert @receipt.reload.failed?
    assert_equal 4000, @receipt.barobill_state
    assert @receipt.last_error.present?
  end

  test "7000(취소) — cancel_pending에서 cancelled 확정" do
    @receipt.update!(state: :cancel_pending, cancel_reason: "오발행 정정")
    with_service(state_ok(7000)) do
      CashReceipt::SyncJob.perform_now(@receipt.id)
    end

    assert @receipt.reload.cancelled?
    assert @receipt.cancelled_at.present?
  end

  test "2500(전송 중) — processing 유지(다음 폴링 대기, CR-003)" do
    with_service(state_ok(2500)) do
      CashReceipt::SyncJob.perform_now(@receipt.id)
    end

    assert @receipt.reload.processing?
    assert_not @receipt.issued? # 응답 확인 전 성공 표시 금지
  end

  test "issued·cancelled 등 확정 상태는 폴링 대상이 아니다" do
    @receipt.update!(state: :issued, nts_confirm_num: "123456789", barobill_state: 3000)
    with_service(state_ok(3000, confirm_num: "999999999")) do
      CashReceipt::SyncJob.perform_now(@receipt.id)
    end
    assert_equal 0, MessageLog.cash_receipt_issued.count # 중복 안내 없음(MSG 유일성)
  end

  test "C1(CR-007) 2500 비종결 — processing 유지 후 SyncJob 재예약(단계 증가 wait)" do
    with_service(state_ok(2500)) do
      assert_enqueued_with job: CashReceipt::SyncJob do
        CashReceipt::SyncJob.perform_now(@receipt.id)
      end
    end

    assert @receipt.reload.processing?
    assert_equal 1, enqueued_jobs_with_poll_count
  end

  test "C1 폴링 실패 — 재예약되고 상한(MAX_POLLS) 도달 시 재예약 중단" do
    with_service(Barobill::BaseService::Result.failure(-1000, "조회 실패")) do
      assert_enqueued_with job: CashReceipt::SyncJob do
        CashReceipt::SyncJob.perform_now(@receipt.id)
      end

      assert_no_enqueued_jobs only: CashReceipt::SyncJob do
        CashReceipt::SyncJob.perform_now(@receipt.id, CashReceipt::SyncJob::MAX_POLLS)
      end
    end

    assert @receipt.reload.processing? # 상태 유지 — 무한 루프 없이 수동 확인 대기
  end

  test "C1(CR-003) 통합 시퀀스 — 2500 재폴링 → 3000 도달 시 issued 확정(중간에 issued 전이 없음)" do
    with_service(state_ok(2500)) do
      assert_no_difference -> { MessageLog.cash_receipt_issued.count } do
        assert_enqueued_with job: CashReceipt::SyncJob do
          CashReceipt::SyncJob.perform_now(@receipt.id)
        end
      end
    end
    assert @receipt.reload.processing? # CR-003: 비종결 상태에서 ISSUED 전이 없음

    # 재예약된 폴링(poll_count=1)이 3000 수신 — issued 확정 + 안내 알림
    with_service(state_ok(3000, confirm_num: "123456789")) do
      assert_difference -> { MessageLog.cash_receipt_issued.count }, 1 do
        CashReceipt::SyncJob.perform_now(@receipt.id, 1)
      end
    end
    assert @receipt.reload.issued?
    assert_equal "123456789", @receipt.nts_confirm_num
  end

  test "R1(W2) cancel_pending에서 3000 폴링 — 알림 미실행·재폴링 지속 후 7000 취소 확정" do
    @receipt.update!(state: :cancel_pending, cancel_reason: "오발행 정정")

    with_service(state_ok(3000, confirm_num: "123456789")) do
      assert_no_difference -> { MessageLog.cash_receipt_issued.count } do
        # R1: 취소 요청 직후 첫 폴링(원본 아직 3000) — 가드 실패해도 재예약으로 폴링 지속
        assert_enqueued_with job: CashReceipt::SyncJob do
          CashReceipt::SyncJob.perform_now(@receipt.id)
        end
      end
    end

    assert @receipt.reload.cancel_pending?
    assert_not @receipt.issued? # CR-003: 가드 실패 시 전이 없음

    # 이후 7000 폴링 — 취소 확정(cancel_pending 고착 없음)
    with_service(state_ok(7000)) do
      CashReceipt::SyncJob.perform_now(@receipt.id, 1)
    end
    assert @receipt.reload.cancelled?
    assert @receipt.cancelled_at.present?
  end

  test "B2 연습 모드 테넌트는 cert_key가 있어도 SIMULATED로 폴링된다(네트워크 0회)" do
    @tenant.update!(practice: true)

    Barobill::BaseService.singleton_class.class_eval do
      alias_method :original_resolve_cert_key, :resolve_cert_key
      define_method(:resolve_cert_key) { "fake-release-key" }
    end
    Barobill::BaseService.class_eval do
      alias_method :original_post_xml, :post_xml
      define_method(:post_xml) { |*| raise "네트워크 호출 금지 — SIMULATED 강제 위반" }
    end
    begin
      CashReceipt::SyncJob.perform_now(@receipt.id)
    ensure
      Barobill::BaseService.singleton_class.class_eval do
        alias_method :resolve_cert_key, :original_resolve_cert_key
        remove_method :original_resolve_cert_key
      end
      Barobill::BaseService.class_eval do
        alias_method :post_xml, :original_post_xml
        remove_method :original_post_xml
      end
    end

    assert @receipt.reload.issued?
    assert_equal "SIMUL3000", @receipt.nts_confirm_num
  end

  private

  def enqueued_jobs_with_poll_count
    queue_adapter.enqueued_jobs.select { |j| j[:job] == CashReceipt::SyncJob }.size
  end
end
