require "test_helper"

module BillingLinks
  class TokenServiceTest < ActiveSupport::TestCase
    setup do
      @tenant, @user = create_owner_user
      @student = create_student_with_guardian(tenant: @tenant)
      @invoice = create_invoice(@tenant, @student, status: :SENT)
    end

    # LNK-001: 예측 불가 토큰 — urlsafe 24바이트(32자)·발급 시각 기록
    test "LNK-001 발급 토큰은 urlsafe 32자 형식이며 발급 시각이 기록된다" do
      result = BillingLinks::TokenService.issue_for(@invoice)

      assert result.issued?
      assert_equal 32, result.token.length
      assert_match(/\A[A-Za-z0-9_-]+\z/, result.token)
      assert_not_nil @invoice.reload.public_token_issued_at
      assert_nil @invoice.public_token_revoked_at
    end

    # LNK-001: URL에 개인정보 직접 포함 금지 — 토큰에 휴대폰번호·원생명이 물리적으로 없다
    test "LNK-001 토큰에는 전화번호·원생명 등 개인정보가 포함되지 않는다" do
      token = BillingLinks::TokenService.issue_for(@invoice).token

      @tenant.users.find_each do |user|
        assert_not_includes token, user.phone_number, "토큰에 원장 휴대폰번호 노출 금지(TEN-003)"
      end
      assert_not_includes token, @student.name
      assert_not_includes token, @tenant.name
    end

    # LNK-001 멱등: 유효 토큰 존재 시 재사용(원장 재클릭 방어)
    test "LNK-001 유효 토큰이 이미 있으면 재사용한다(멱등)" do
      first = BillingLinks::TokenService.issue_for(@invoice)
      second = BillingLinks::TokenService.issue_for(@invoice)

      assert first.issued?
      assert second.reused?
      assert_equal first.token, second.token
      assert_not_nil @invoice.reload.public_token_issued_at
    end

    # 유니크 인덱스 충돌 — 다른 토큰으로 재시도(무한 재시도 아님, 상한 내)
    test "전역 유니크 충돌 시 재시도해 다른 토큰으로 발급한다" do
      first = BillingLinks::TokenService.issue_for(@invoice)
      other = create_invoice(@tenant, @student, status: :SENT, target_month: "2026-09")

      # 첫 생성 호출만 충돌 토큰(first.token)을 반환하고 이후는 원본 위임(cash_receipt_triggerable_test 패턴)
      original = SecureRandom.method(:urlsafe_base64)
      calls = 0
      begin
        SecureRandom.define_singleton_method(:urlsafe_base64) do |*args, **kwargs|
          calls += 1
          calls == 1 ? first.token : original.call(*args, **kwargs)
        end

        result = BillingLinks::TokenService.issue_for(other)
      ensure
        SecureRandom.singleton_class.send(:remove_method, :urlsafe_base64) # 스텁 누수 방지 — 모듈 싱글턴 원본 복원
      end

      assert result.issued?
      assert_equal 2, calls
      assert_not_equal first.token, other.reload.public_token
    end

    # LNK-003: 재발급 — 이전 토큰 즉시 만료
    # (Result#token은 invoice.public_token 라이브 위임이므로 이전 토큰은 문자열로 스냅샷해 비교)
    test "LNK-003 재발급하면 이전 토큰은 만료되고 새 토큰으로만 조회된다" do
      old = BillingLinks::TokenService.issue_for(@invoice).token
      new = BillingLinks::TokenService.reissue_for(@invoice)

      assert new.issued?
      assert_not_equal old, new.token
      assert_nil BillingLinks::TokenService.find_active_by_token(old)
      assert_equal @invoice.id, BillingLinks::TokenService.find_active_by_token(new.token)&.id
    end

    # LNK-003: 폐기 — 만료·폐기 링크는 조회 불가(정보 미노출)
    test "LNK-003 폐기된 토큰은 find_active_by_token이 nil을 반환한다" do
      issued = BillingLinks::TokenService.issue_for(@invoice)

      result = BillingLinks::TokenService.revoke_for(@invoice)

      assert result.revoked?
      assert_not_nil @invoice.reload.public_token_revoked_at
      assert_nil BillingLinks::TokenService.find_active_by_token(issued.token)
    end

    # 폐기 멱등 — 최초 폐기 시각 유지
    test "이미 폐기된 청구의 재폐기 요청은 최초 폐기 시각을 유지한다" do
      BillingLinks::TokenService.revoke_for(@invoice)
      first_revoked_at = @invoice.reload.public_token_revoked_at

      result = BillingLinks::TokenService.revoke_for(@invoice)

      assert result.revoked?
      assert_equal first_revoked_at, @invoice.reload.public_token_revoked_at
    end

    # 폐기된 토큰 보유 청구는 재사용하지 않고 신규 발급
    test "폐기된 토큰이 있으면 issue_for는 신규 발급한다(재사용 금지)" do
      old = BillingLinks::TokenService.issue_for(@invoice).token
      BillingLinks::TokenService.revoke_for(@invoice)

      result = BillingLinks::TokenService.issue_for(@invoice)

      assert result.issued?
      assert_not_equal old, result.token
      assert_nil @invoice.reload.public_token_revoked_at
    end

    # LNK-003/INV-003: 취소(CANCELLED) 청구는 발급·재발급하지 않는다 — 공개 페이지 재노출 차단
    test "취소 청구의 발급·재발급은 거절되고 토큰이 발급되지 않는다" do
      assert @invoice.cancel!("청구 취소") # cancel! 연계로 토큰 미발급 상태

      issued = BillingLinks::TokenService.issue_for(@invoice)
      reissued = BillingLinks::TokenService.reissue_for(@invoice)

      assert issued.blocked?
      assert reissued.blocked?
      assert_nil @invoice.reload.public_token
    end

    # 취소 청구의 기존 유효 토큰은 cancel! 연계로 이미 폐기 — blocked 시 갱신도 없음
    test "취소 청구 재발급 시도로 유효 토큰이 부활하지 않는다" do
      BillingLinks::TokenService.issue_for(@invoice)
      assert @invoice.cancel!("청구 취소")
      assert @invoice.reload.public_token_revoked_at.present?

      result = BillingLinks::TokenService.issue_for(@invoice)

      assert result.blocked?
      assert @invoice.reload.public_token_revoked_at.present? # 폐기 상태 유지 — 활성 토큰 없음
      assert_nil BillingLinks::TokenService.find_active_by_token(@invoice.public_token)
    end

    # 불일치·빈 토큰 — nil (뷰에서 만료 안내로 분기)
    test "불일치·빈 토큰 조회는 nil을 반환한다" do
      BillingLinks::TokenService.issue_for(@invoice)

      assert_nil BillingLinks::TokenService.find_active_by_token("unknown-token-value")
      assert_nil BillingLinks::TokenService.find_active_by_token("")
      assert_nil BillingLinks::TokenService.find_active_by_token(nil)
    end

    # TEN-001: 토큰은 청구마다 고유 — 토큰 조회 결과는 해당 청구 단일 건
    test "TEN-001 토큰은 청구별로 고유하며 자기 청구만 반환한다" do
      other_student = create_student_with_guardian(tenant: @tenant, name: "박서준")
      other = create_invoice(@tenant, other_student, status: :SENT, target_month: "2026-09")

      token_a = BillingLinks::TokenService.issue_for(@invoice).token
      token_b = BillingLinks::TokenService.issue_for(other).token

      assert_not_equal token_a, token_b
      assert_equal @invoice.id, BillingLinks::TokenService.find_active_by_token(token_a).id
      assert_equal other.id, BillingLinks::TokenService.find_active_by_token(token_b).id
    end
  end
end
