# frozen_string_literal: true

# 발송 유일성 테스트 — MSG-001(모델 검증 + DB partial unique index + 재발송 예외)
class MessageLogTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "메시지테스트 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT, sent_at: Time.current)
  end

  def build_log(template_type: :invoice_notice, status: :QUEUED)
    MessageLog.new(tenant: @tenant, invoice: @invoice, student: @student,
                   template_type: template_type, status: status)
  end

  # MSG-001: 동일 청구 × 템플릿 유형 중복 발송 차단(모델 검증)
  test "MSG-001 동일 청구 같은 템플릿 중복 생성은 검증으로 차단된다" do
    build_log.save!
    duplicate = build_log

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:base, :duplicate_dispatch)
  end

  # MSG-001: 템플릿 유형이 다르면 각 1건 허용(단계별 유일성 — F6)
  test "MSG-001 템플릿 유형이 다르면 발송 가능하다" do
    build_log.save!

    assert build_log(template_type: :reminder_d3).valid?
  end

  # MSG-001: DB partial unique index — 검증 우회 동시 삽입도 차단(C1 회귀)
  test "MSG-001 검증 우회 삽입은 partial unique 인덱스로 차단된다" do
    log = build_log
    log.save!(validate: false)

    assert_raises(ActiveRecord::RecordNotUnique) do
      build_log.save!(validate: false)
    end
  end

  # MSG-001: partial unique index 존재 확인(동시 삽입 방어의 DB 축 — CRITICAL-1 회귀)
  test "MSG-001 partial unique 인덱스가 존재한다" do
    index = ActiveRecord::Base.connection.indexes(:message_logs)
                                  .find { |candidate| candidate.unique && candidate.columns == %w[invoice_id template_type] }

    assert_not_nil index, "dispatch uniqueness unique 인덱스 없음"
    assert_equal "resend_of_id IS NULL", index.where
  end

  # MSG-001: '다시 보내기'는 resend_of 설정 시 예외 허용 + 이력 연결(W8 회귀)
  test "MSG-001 재발송은 resend_of 연결 시 허용되고 원본과 연결된다" do
    original = build_log
    original.save!

    resend = build_log
    resend.resend_of = original

    assert_difference -> { original.reload.resends.count }, 1 do
      assert resend.save, resend.errors.full_messages.join(", ")
    end
    assert_equal original.id, resend.resend_of_id
  end

  # MSG-001: resend_of 없는 재발송 시도는 예외 아님 — 검증 차단
  test "MSG-001 resend_of 없는 중복은 재발송으로도 인정되지 않는다" do
    build_log.save!

    assert_not build_log.valid?
  end

  # 9.3/MSG-007: QUEUED 대기열 건만 취소 가능
  test "MSG-007 예약 취소 가능 여부는 QUEUED뿐이다" do
    assert build_log.cancellable?
    assert_not build_log(status: :SENT).cancellable?
  end
end
