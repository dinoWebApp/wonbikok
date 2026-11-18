# F9 학부모 청구 링크 토큰 발급·관리(PRD 8장, 22장 LNK).
# LNK-001: 토큰은 SecureRandom.urlsafe_base64(24) — 32자 urlsafe, 예측 불가·URL에 개인정보 미포함.
# LNK-003: 재발급 시 기존 토큰 즉시 만료, 만료·폐기 링크는 find_active_by_token이 nil 반환.
# [3-S 가정] invoices.public_token(string·유니크 인덱스)·public_token_issued_at·public_token_revoked_at
# 컬럼 존재 전제 — 마이그레이션은 통합(Phase 3-S)에서 단 1회 생성.
module BillingLinks
  class TokenService
    TOKEN_BYTES = 24      # → urlsafe 32자 (개발 가이드: base64 24 이상)
    RETRY_LIMIT = 5       # 유니크 충돌 재시도 상한 — 무한 재시도 금지

    Result = Data.define(:invoice, :outcome) do
      def token = invoice.public_token
      def issued? = outcome == :issued
      def reused? = outcome == :reused # 멱등: 유효 토큰이 이미 있어 재사용(신규 발급 아님)
      def revoked? = outcome == :revoked
      def blocked? = outcome == :blocked # 취소(CANCELLED) 청구 — 발급·재발급 거절(LNK-003/INV-003)
    end

    class << self
      # 토큰 발급(멱등) — 유효 토큰이 이미 있으면 재사용한다(원장 재클릭·재요청 방어).
      # 취소(CANCELLED) 청구는 발급하지 않는다 — 취소 청구 공개 페이지 재노출 차단(LNK-003/INV-003).
      def issue_for(invoice)
        return Result.new(invoice: invoice, outcome: :blocked) if invoice.CANCELLED?
        return Result.new(invoice: invoice, outcome: :reused) if active_token?(invoice)

        issue_new!(invoice)
        Result.new(invoice: invoice, outcome: :issued)
      end

      # 재발급(LNK-003) — 기존 토큰 폐기 기록 후 신규 발급 → 이전 토큰 즉시 만료.
      def reissue_for(invoice)
        return Result.new(invoice: invoice, outcome: :blocked) if invoice.CANCELLED?

        revoke_for(invoice)
        issue_new!(invoice)
        Result.new(invoice: invoice, outcome: :issued)
      end

      # 링크 폐기(원장 취소) — 최초 폐기 시각 유지. 이후 find_active_by_token은 nil.
      def revoke_for(invoice)
        return Result.new(invoice: invoice, outcome: :revoked) if invoice.public_token_revoked_at.present?

        invoice.update!(public_token_revoked_at: Time.current)
        Result.new(invoice: invoice, outcome: :revoked)
      end

      # 유효(미폐기) 청구만 반환 — 불일치·폐기 토큰은 nil(LNK-003: 만료 링크 정보 미노출).
      # 토큰은 전역 유니크이므로 조회 결과는 단일 청구로 확정된다(TEN-001: 페이지는 해당 청구만).
      def find_active_by_token(token)
        return nil if token.to_s.blank?

        Invoice.find_by(public_token: token.to_s, public_token_revoked_at: nil)
      end

      private

      def active_token?(invoice)
        invoice.public_token.present? && invoice.public_token_revoked_at.nil?
      end

      def issue_new!(invoice)
        attempts = 0
        begin
          invoice.update!(
            public_token: SecureRandom.urlsafe_base64(TOKEN_BYTES),
            public_token_issued_at: Time.current,
            public_token_revoked_at: nil
          )
        rescue ActiveRecord::RecordNotUnique
          # 전역 유니크 인덱스 충돌 — 다른 토큰으로 재시도(상한 내).
          attempts += 1
          raise if attempts >= RETRY_LIMIT

          retry
        end
      end
    end
  end
end
