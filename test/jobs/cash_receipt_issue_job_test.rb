require "test_helper"

class CashReceiptIssueJobTest < ActiveJob::TestCase
  setup do
    @tenant, @user = create_owner_user
    @tenant.update!(barobill_member_id: "wonbi1")
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT)
    @receipt = CashReceipt.create!(
      tenant: @tenant, invoice: @invoice,
      mgt_key: CashReceipt.build_mgt_key(@invoice, :income_deduction),
      issue_type: :income_deduction, state: :pending,
      amount: @invoice.total_amount, trade_date: Time.current, identity_num: "01011112222"
    )
  end

  ServiceStub = Data.define(:issue_response, :state_response) do
    def regist_and_issue(mgt_key:, cash_bill:) = issue_response
    def state(mgt_key:) = state_response
  end

  def service_stub(issue_response:, state_response: nil)
    ServiceStub.new(issue_response, state_response)
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

  def job_with(service:, executions: 1)
    job = CashReceipt::IssueJob.new
    job.singleton_class.class_eval do
      define_method(:executions) { executions }
      define_method(:issue_service_for) { |_| service }
      define_method(:cash_bill_for) { |_| {} }
      define_method(:lookup_existing_state) { |_| service.state_response&.success? ? service.state_response.value : nil }
    end
    job
  end

  def failure(code = -10_001, message = "일시 오류")
    Barobill::BaseService::Result.failure(code, message)
  end

  def state_ok(state, confirm_num: nil)
    Barobill::BaseService::Result.ok(
      value: { barobill_state: state, nts_confirm_num: confirm_num, nts_confirm_message: nil }
    )
  end

  test "SIMULATED 발행 — processing 전이 후 SyncJob 예약(CR-003: 즉시 issued 아님)" do
    assert_enqueued_with job: CashReceipt::SyncJob do
      CashReceipt::IssueJob.perform_now(@receipt.id)
    end
    assert @receipt.reload.processing?
    assert_not @receipt.issued?
  end

  test "SIMULATED 전체 플로우 — IssueJob + SyncJob 실행 시 issued 확정(3000·승인번호)" do
    CashReceipt::IssueJob.perform_now(@receipt.id)
    CashReceipt::SyncJob.perform_now(@receipt.id)

    @receipt.reload
    assert @receipt.issued?
    assert_equal 3000, @receipt.barobill_state
    assert_equal "SIMUL3000", @receipt.nts_confirm_num
  end

  test "CR-004 발행 요청 실패해도 재조회에서 3000 기발행이면 failed로 표시하지 않는다" do
    service = service_stub(issue_response: failure, state_response: state_ok(3000, confirm_num: "123456789"))

    assert_enqueued_with job: CashReceipt::SyncJob do
      job_with(service: service, executions: 1).perform(@receipt.id)
    end
    assert @receipt.reload.processing? # CR-004: 기발행 확인 → 폴링으로 확정
  end

  test "CR-006 실패 1회째는 pending 복귀 후 재시도 예약(R2)" do
    service = service_stub(issue_response: failure, state_response: failure(-1000, "조회 실패"))
    job = job_with(service: service, executions: 1)

    assert_enqueued_with job: CashReceipt::IssueJob do
      job.perform(@receipt.id)
    end

    assert @receipt.reload.pending? # pending 복귀 — 2회째가 실제 재발행을 수행
  end

  test "CR-006 재시도 소진(2회째 실패) 후 failed + 원장 알림 기록" do
    service = service_stub(issue_response: failure, state_response: failure(-1000, "조회 실패"))

    assert_difference -> { MessageLog.cash_receipt_failed.count }, 1 do
      job_with(service: service, executions: 2).perform(@receipt.id)
    end
    assert @receipt.reload.failed?
    assert_equal "일시 오류", @receipt.last_error
  end

  # W3-R(3차 리뷰): 스텁을 호출 횟수 기반으로 교체 — state() 첫 호출(1회째 실패 후 재조회,
  # CR-004 lookup_existing_state)은 조회 실패를 반환해 CR-004 기발행 분기 흡수를 차단하고,
  # 2회째 이후(2회째 실행 후 SyncJob 폴링)만 3000을 반환한다. 이로써 2회째 실행이
  # regist_and_issue 재호출(실제 재발행)로 issued에 도달함을 직접 검증한다.
  test "R2(B1) retry_job 2회째 실제 재발행 — 1회 실패·조회 실패→pending 복귀→2회째 발행 성공 후 issued" do
    service_class = Class.new do
      attr_reader :issue_calls, :state_calls

      def initialize
        @issue_calls = 0
        @state_calls = 0
      end

      def regist_and_issue(mgt_key:, cash_bill:)
        @issue_calls += 1
        if @issue_calls == 1
          Barobill::BaseService::Result.failure(-10_001, "일시 오류")
        else
          Barobill::BaseService::Result.ok(value: "1")
        end
      end

      def state(mgt_key:)
        @state_calls += 1
        if @state_calls == 1
          Barobill::BaseService::Result.failure(-1000, "조회 실패") # CR-004 재조회 실패 → 재발행 경로
        else
          Barobill::BaseService::Result.ok(
            value: { barobill_state: 3000, nts_confirm_num: "123456789", nts_confirm_message: nil }
          )
        end
      end
    end

    service = service_class.new
    stub_service_builder(service) do
      # 스텁 없는 실제 retry_job 경유 — 1회째 실패 → pending 복귀·재시도 → 2회째 재발행 성공
      perform_enqueued_jobs do
        CashReceipt::IssueJob.perform_later(@receipt.id)
      end
    end

    assert @receipt.reload.issued?
    assert_equal "123456789", @receipt.nts_confirm_num
    # CR-004 분기 흡수가 아닌 실제 재발행: regist_and_issue 2회 호출 검증
    assert_equal 2, service.issue_calls
    assert_equal 2, service.state_calls # 1회째 재조회(실패) + 2회째 폴링(3000)
  end

  test "R2(B1) retry_job 2회째 실제 수행 — 재발행 재실패 시 failed + 원장 알림(CR-006 소진 도달)" do
    service = service_stub(issue_response: failure, state_response: failure(-1000, "조회 실패"))

    assert_difference -> { MessageLog.cash_receipt_failed.count }, 1 do
      stub_service_builder(service) do
        perform_enqueued_jobs do
          CashReceipt::IssueJob.perform_later(@receipt.id)
        end
      end
    end

    assert @receipt.reload.failed?
    assert_equal "일시 오류", @receipt.last_error
  end

  test "B2 연습 모드 테넌트는 cert_key가 있어도 SIMULATED로 발행된다(네트워크 0회)" do
    @tenant.update!(practice: true)

    stub_resolve_cert_key("fake-release-key") do
      forbid_network do
        CashReceipt::IssueJob.perform_now(@receipt.id)
        CashReceipt::SyncJob.perform_now(@receipt.id)
      end
    end

    assert @receipt.reload.issued?
    assert_equal "SIMUL3000", @receipt.nts_confirm_num # SIMULATED 기록 — 실바로빌 호출 없음
  end
end
