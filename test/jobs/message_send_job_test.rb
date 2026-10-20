# frozen_string_literal: true

# 발송 잡 테스트 — 외부 API 스텁(실호출 금지) — MSG-002/003, SIMULATED 격리, 취소 청구 가드(C4)
class MessageSendJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @original_from_credentials = Solapi::Client.method(:from_credentials)
    @tenant = Tenant.create!(name: "잡테스트 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student)
    @invoice.confirm!
    @log = @invoice.message_logs.create!(tenant: @tenant, student: @student,
                                         template_type: :invoice_notice, status: :QUEUED)
  end

  teardown do
    Solapi::Client.define_singleton_method(:from_credentials, @original_from_credentials)
  end

  def stub_client(result)
    client = FakeSolapiClient.new(result)
    Solapi::Client.define_singleton_method(:from_credentials) { client }
    client
  end

  # 키 검사를 우회해 실호출 경로를 강제하는 잡(외부 호출은 스텁이 응답)
  def live_job(executions: 0)
    job = MessageSendJob.new
    job.executions = executions
    job.define_singleton_method(:simulated?) { |_candidate| false }
    job
  end

  # 연습 모드 격리: 실호출 0건 — SIMULATED 기록 + 청구 SENT
  test "practice 테넌트는 실호출 없이 SIMULATED로 기록된다" do
    @tenant.update!(practice: true)
    client = stub_client(Solapi::Client::Result.success(message_id: "x", group_id: "g", fallback: false))

    MessageSendJob.perform_now(@log.id)

    assert_equal 0, client.call_count
    assert_equal "SIMULATED", @log.reload.status
    assert @invoice.reload.SENT?
  end

  # 정상 발송: SENT + provider_message_id + 청구 SENT 전이
  test "성공 응답은 SENT로 기록하고 청구를 SENT로 전이한다" do
    stub_client(Solapi::Client::Result.success(message_id: "msg_123", group_id: "grp_1",
                                               fallback: false))
    live_job.perform(@log.id)

    assert_equal "SENT", @log.reload.status
    assert_equal "msg_123", @log.reload.provider_message_id
    assert @invoice.reload.SENT?
  end

  # MSG-002: 알림톡 실패 → 대체발송 성공 응답은 FALLBACK_SENT로 채널 구분 기록
  test "MSG-002 대체발송 성공은 FALLBACK_SENT로 기록된다" do
    stub_client(Solapi::Client::Result.success(message_id: "msg_fallback", group_id: "grp_2",
                                               fallback: true))
    live_job.perform(@log.id)

    assert_equal "FALLBACK_SENT", @log.reload.status
    assert @invoice.reload.SENT?
  end

  # C4: 취소된 청구의 발송은 차단 — FAILED(INVOICE_CANCELLED), 클라이언트 미호출
  test "INV-003 취소된 청구의 발송은 INVOICE_CANCELLED로 차단된다" do
    @invoice.cancel!("중복 발급")
    client = stub_client(Solapi::Client::Result.success(message_id: "x", group_id: "g",
                                                        fallback: false))

    MessageSendJob.perform_now(@log.id)

    assert_equal 0, client.call_count
    assert_equal "FAILED", @log.reload.status
    assert_equal "INVOICE_CANCELLED", @log.error_code
    assert_not @invoice.reload.SENT? # 취소 상태 유지
  end

  # MSG-003: 1차 실패(네트워크 오류) — 정확 1회 재시도 예약
  test "MSG-003 1차 실패 시 재시도가 1회 예약된다" do
    stub_client(Solapi::Client::Result.failure("NETWORK_ERROR", "Timeout::Error"))

    assert_enqueued_jobs 1, only: MessageSendJob do
      live_job.perform(@log.id)
    end
    assert_not_equal "FAILED", @log.reload.status # 아직 확정 아님
  end

  # MSG-003: 2차 실패(executions=1) 후 재시도 없음 — FAILED 확정
  test "MSG-003 2차 실패 후에는 재시도가 없다" do
    stub_client(Solapi::Client::Result.failure("NETWORK_ERROR", "Timeout::Error"))

    assert_no_enqueued_jobs do
      live_job(executions: 1).perform(@log.id)
    end
    assert_equal "FAILED", @log.reload.status
    assert_equal "NETWORK_ERROR", @log.error_code
  end

  # MSG-003: 3차(executions=2)는 상한 초과로 FAILED 확정(구현 기준 경계)
  test "MSG-003 3차 실패는 재시도 없이 FAILED다" do
    stub_client(Solapi::Client::Result.failure("NETWORK_ERROR", "Timeout::Error"))

    assert_no_enqueued_jobs do
      live_job(executions: 2).perform(@log.id)
    end
    assert_equal "FAILED", @log.reload.status
  end

  # MSG-003: ConfigError는 재시도 0회 즉시 확정
  test "MSG-003 설정 오류는 재시도 없이 즉시 FAILED다" do
    Solapi::Client.define_singleton_method(:from_credentials) do
      raise Solapi::Client::ConfigError, "api_key 미설정"
    end

    assert_no_enqueued_jobs do
      live_job.perform(@log.id)
    end
    assert_equal "FAILED", @log.reload.status
    assert_equal "CONFIG_ERROR", @log.error_code
  end

  # 수신처 부재 방어: 잡 단독 재실행 시 보호자 부재 → FAILED(NO_RECIPIENT)
  test "보호자가 없으면 NO_RECIPIENT로 실패 확정된다" do
    @student.guardians.destroy_all

    MessageSendJob.perform_now(@log.id)

    assert_equal "FAILED", @log.reload.status
    assert_equal "NO_RECIPIENT", @log.error_code
  end
end

# 솔라피 실호출 대체 스텁 — 호출 카운터 보유(연습 모드 0호출 검증용)
class FakeSolapiClient
  attr_reader :call_count

  def initialize(result)
    @result = result
    @call_count = 0
  end

  def send_messages(_messages, scheduled_date: nil)
    @call_count += 1
    @result
  end
end
