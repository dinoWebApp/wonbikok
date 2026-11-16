# frozen_string_literal: true

module Barobill
  # 바로빌 현금영수증 API 어댑터(PRD 10.2 — 발급대행).
  # 메서드 매핑: 발행=RegistAndIssueCashBill / 상태=GetCashBillInfo(상태+승인번호) /
  # 전건 취소=CancelCashBillEx / 부분 취소=CancelCashBillPartialEx / 학부모 조회=GetCashBillMailURL.
  # ※ 직접 HTTP 규격상 복합형(CashBillEx) 자식 태그 규격은 스파이크(테스트키)에서 검증할 항목.
  class CashReceiptService < BaseService
    # CashBillEx 필수 필드(PRD 10.2) — 발행 요청 전 사전 검증(Tel 누락 등을 조기 차단)
    REQUIRED_CASH_BILL_FIELDS = %i[
      FranchiseCorpNum MemberID CorpName CEOName Addr Tel IdentityNum
      TradeType TradeUsage TradeMethod Amount Tax ServiceCharge
    ].freeze

    TRADE_METHOD_MOBILE = 5 # 휴대폰 결제(F5 기준값)
    SIMULATED_STATE = 3000

    def initialize(cert_key:, corp_num:, member_id:)
      super(cert_key: cert_key)
      @corp_num = corp_num.to_s
      @member_id = member_id.to_s
    end

    # 테넌트(회원사) 기준 구성 — credentials 키 + tenants(barobill_member_id) 결합.
    # 환경 분기(PRD 10.2): production=release_auth_key+ws / 그 외=test_auth_key+testws.
    # B2 연습 모드 가드(PRD 14장 W2 선례 준용 — message_send_job): practice 테넌트는
    # cert_key가 설정되어 있어도 SIMULATED 강제 — IssueJob·SyncJob·CancelService 전 경로가
    # 본 빌더를 경유하므로 실제 바로빌 호출(과금·국세청 신고)이 차단된다.
    def self.from_credentials_with_tenant(tenant)
      cert_key = tenant.practice? ? "" : BaseService.resolve_cert_key
      new(cert_key: cert_key, corp_num: tenant.business_number, member_id: tenant.barobill_member_id)
    end

    # 발행(멱등 — MgtKey). 성공(1)이라도 CR-003에 따라 즉시 issued 처리하지 않는다 —
    # SyncJob 상태 폴링으로 확정한다.
    def regist_and_issue(mgt_key:, cash_bill:)
      missing_fields = REQUIRED_CASH_BILL_FIELDS.select { |f| cash_bill[f].to_s.strip.empty? }
      return Result.failure(:missing_field, "필수 필드 누락: #{missing_fields.join(', ')}") if missing_fields.any?

      call("RegistAndIssueCashBill", [
        [ :CERTKEY, cert_key ],
        [ :CorpNum, @corp_num ],
        [ :UserID, @member_id ],
        [ :CashBillEx, cash_bill_ex_xml(mgt_key, cash_bill) ]
      ])
    end

    # 상태+승인번호 조회(GetCashBillInfo) → { barobill_state:, nts_confirm_num:, nts_confirm_message: }
    def state(mgt_key:)
      fields = [
        [ :CERTKEY, cert_key ],
        [ :CorpNum, @corp_num ],
        [ :UserID, @member_id ],
        [ :MgtKey, mgt_key ]
      ]

      doc = raw_result_doc("GetCashBillInfo", fields)
      if doc.nil? # SIMULATED — 외부 호출 없이 3000(전송 완료) 시뮬레이션
        return Result.ok(value: { barobill_state: SIMULATED_STATE, nts_confirm_num: "SIMUL3000",
                                  nts_confirm_message: "SIMULATED" })
      end

      result_node = doc.at_xpath("//*[local-name()='GetCashBillInfoResult']")
      return Result.failure(:invalid_response, I18n.t("barobill.errors.default", code: "INVALID_RESPONSE")) if result_node.nil?

      barobill_state = result_node.text.to_i
      return Result.failure(barobill_state, error_message_for(barobill_state)) if barobill_state.negative?

      confirm_num = doc.at_xpath("//*[local-name()='NtsconfirmNum']")&.text.to_s
      Result.ok(value: { barobill_state: barobill_state, nts_confirm_num: confirm_num,
                         nts_confirm_message: nil })
    end

    # 전건 취소(CancelCashBillEx — 새 취소거래 건 발급, CR-005)
    def cancel(mgt_key:, cancel_mgt_key:)
      call("CancelCashBillEx", [
        [ :CERTKEY, cert_key ],
        [ :CorpNum, @corp_num ],
        [ :UserID, @member_id ],
        [ :MgtKey, mgt_key ],
        [ :CancelMgtKey, cancel_mgt_key ]
      ])
    end

    # 부분 취소(CancelCashBillPartialEx)
    def partial_cancel(mgt_key:, cancel_mgt_key:, amount:, tax: 0, service_charge: 0)
      call("CancelCashBillPartialEx", [
        [ :CERTKEY, cert_key ],
        [ :CorpNum, @corp_num ],
        [ :UserID, @member_id ],
        [ :MgtKey, mgt_key ],
        [ :CancelMgtKey, cancel_mgt_key ],
        [ :CancelAmount, amount ],
        [ :CancelTax, tax ],
        [ :CancelServiceCharge, service_charge ]
      ])
    end

    # 학부모 현금영수증 조회 URL(GetCashBillMailURL — 60초 유효, NK=구매자)
    def mail_url(mgt_key:)
      call("GetCashBillMailURL", [
        [ :CERTKEY, cert_key ],
        [ :CorpNum, @corp_num ],
        [ :UserID, @member_id ],
        [ :MgtKey, mgt_key ],
        [ :Type, "NK" ]
      ])
    end

    private

    # CashBillEx 복합형 직렬화 — 필드 순서 보관(WSDL 규격 가정, 스파이크 대조 대상)
    def cash_bill_ex_xml(mgt_key, cash_bill)
      ordered = %i[FranchiseCorpNum MemberID CorpName CEOName Addr Tel IdentityNum HP Email
                   TradeType TradeUsage TradeMethod Amount Tax ServiceCharge ItemName]
      children = [ "<ns:MgtKey>#{CGI.escapeHTML(mgt_key)}</ns:MgtKey>" ]
      ordered.each do |field|
        value = field == :TradeMethod ? (cash_bill[field] || TRADE_METHOD_MOBILE) : cash_bill[field]
        next if value.to_s.strip.empty?

        children << "<ns:#{field}>#{CGI.escapeHTML(value.to_s)}</ns:#{field}>"
      end
      RawXml.new(xml: children.join)
    end

    # SIMULATED — 메서드별 성공 시뮬레이션 값(외부 호출 없음)
    def simulated_value_for(method_name)
      case method_name
      when "RegistAndIssueCashBill" then "1"
      when "GetCashBillInfo" then SIMULATED_STATE.to_s
      when "CancelCashBillEx", "CancelCashBillPartialEx" then "1"
      when "GetCashBillMailURL" then "https://simulated.barobill.test/receipt/#{SecureRandom.hex(6)}"
      end
    end
  end
end
