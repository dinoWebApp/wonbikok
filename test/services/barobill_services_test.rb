require "test_helper"

module Barobill
  # 바로빌 어댑터 단위 테스트 — 외부 API 실호출 금지(스텁 XML·SIMULATED만)
  class BarobillServicesTest < ActiveSupport::TestCase
    SERVICE_NS = Barobill

    # ---- SIMULATED 분기 ----

    test "cert_key 공백이면 SIMULATED 모드 — 외부 호출 없이 성공 응답" do
      service = CashReceiptService.new(cert_key: "  ", corp_num: "1234567890", member_id: "wonbi1")

      assert service.simulated?
      forbid_network(service)
      result = service.regist_and_issue(mgt_key: "CR1", cash_bill: full_cash_bill)
      assert result.success?
      assert_equal 1, result.value.to_i
    end

    test "SIMULATED 상태 조회 — 3000·승인번호 SIMUL3000" do
      service = CashReceiptService.new(cert_key: "", corp_num: "1234567890", member_id: "wonbi1")
      result = service.state(mgt_key: "CR1")

      assert result.success?
      assert_equal 3000, result.value[:barobill_state]
      assert_equal "SIMUL3000", result.value[:nts_confirm_num]
    end

    # ---- CashBillEx 필수 필드 검증 ----

    test "CashBillEx 필수 필드 누락 시 외부 호출 없이 실패 반환" do
      service = CashReceiptService.new(cert_key: "", corp_num: "1234567890", member_id: "wonbi1")
      bill = full_cash_bill
      bill.delete(:FranchiseTel) # 가맹점 전화 필수

      forbid_network(service)
      result = service.regist_and_issue(mgt_key: "CR1", cash_bill: bill)

      assert_not result.success?
      assert_match(/Tel/, result.message)
    end

    # ---- 스텁 XML 파싱(직접 HTTP 규격) ----

    def stub_post_xml(service, xml)
      service.singleton_class.class_eval do
        define_method(:post_xml) { |_, _| xml }
      end
    end

    test "성공 응답 스텁 XML 파싱 — Result 값 반환" do
      service = CashReceiptService.new(cert_key: "TESTKEY", corp_num: "1234567890", member_id: "wonbi1")
      stub_post_xml(service, <<~XML)
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <RegistAndIssueCashBillResponse xmlns="http://ws.baroservice.com/">
              <RegistAndIssueCashBillResult>1</RegistAndIssueCashBillResult>
            </RegistAndIssueCashBillResponse>
          </soap:Body>
        </soap:Envelope>
      XML

      result = service.regist_and_issue(mgt_key: "CR1", cash_bill: full_cash_bill)

      assert result.success?
      assert_equal "1", result.value
    end

    test "오류코드 음수 응답 스텁 XML 파싱 — failure 반환(-10001)" do
      service = CashReceiptService.new(cert_key: "TESTKEY", corp_num: "1234567890", member_id: "wonbi1")
      stub_post_xml(service, <<~XML)
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <GetCashBillStateResponse xmlns="http://ws.baroservice.com/">
              <GetCashBillStateResult>-10001</GetCashBillStateResult>
            </GetCashBillStateResponse>
          </soap:Body>
        </soap:Envelope>
      XML

      result = service.state(mgt_key: "CR1")

      assert_not result.success?
      assert_equal(-10_001, result.code)
    end

    test "복합형 응답 파싱 — GetCashBillStateResult 내부 BarobillState·NTSConfirmNum 자식 추출(3000=issued)" do
      service = CashReceiptService.new(cert_key: "TESTKEY", corp_num: "1234567890", member_id: "wonbi1")
      stub_post_xml(service, state_response_xml(3000, confirm_num: "987654321"))

      result = service.state(mgt_key: "CR1")

      assert result.success?
      assert_equal 3000, result.value[:barobill_state]
      assert_equal "987654321", result.value[:nts_confirm_num]
      assert_nil result.value[:nts_confirm_message]
    end

    test "복합형 응답 파싱 — 2000(전송 중)도 success 반환(processing 유지·SyncJob 재폴링)" do
      service = CashReceiptService.new(cert_key: "TESTKEY", corp_num: "1234567890", member_id: "wonbi1")
      stub_post_xml(service, state_response_xml(2000))

      result = service.state(mgt_key: "CR1")

      assert result.success?
      assert_equal 2000, result.value[:barobill_state]
      assert_equal "", result.value[:nts_confirm_num]
    end

    test "복합형 응답 파싱 — NTSConfirmMessage 값 반영(4000 실패 사유용)" do
      service = CashReceiptService.new(cert_key: "TESTKEY", corp_num: "1234567890", member_id: "wonbi1")
      stub_post_xml(service, state_response_xml(4000, message: "확인요소오류"))

      result = service.state(mgt_key: "CR1")

      assert result.success?
      assert_equal "확인요소오류", result.value[:nts_confirm_message]
    end

    test "복합형 응답 파싱 — NTSConfirmNum(대문자 표기) 노드도 local-name 탐색으로 추출" do
      service = CashReceiptService.new(cert_key: "TESTKEY", corp_num: "1234567890", member_id: "wonbi1")
      stub_post_xml(service, state_response_xml(3000, confirm_num: "987654321", variant: "NtsConfirmNum"))

      result = service.state(mgt_key: "CR1")

      assert result.success?
      assert_equal "987654321", result.value[:nts_confirm_num]
    end

    # ---- 환경별 엔드포인트·키 선택 ----

    test "환경 분기 — production은 운영키+ws, 그 외는 테스트키+testws (SIMULATED 검증)" do
      assert BaseService.simulated?("")
      assert BaseService.simulated?(nil)
      assert_not BaseService.simulated?("REALKEY")
    end

    test "엔벨로프 구성 — CERTKEY·네임스페이스·SOAPAction 규격" do
      service = CashReceiptService.new(cert_key: "KEY", corp_num: "1234567890", member_id: "wonbi1")
      envelope = service.send(:build_envelope, "GetCashBillInfo", [
        [ :CERTKEY, "KEY" ], [ :CorpNum, "1234567890" ], [ :MgtKey, "CR1" ]
      ])

      assert_includes envelope, 'xmlns:ns="http://ws.baroservice.com/"'
      assert_includes envelope, "<ns:CERTKEY>KEY</ns:CERTKEY>"
      assert_includes envelope, "<ns:MgtKey>CR1</ns:MgtKey>"
      assert_includes envelope, "<ns:GetCashBillInfo>"
    end

    test "발행 엔벨로프 — Invoice 태그·SMSSendYN 필수 파라미터 포함(WSDL 실측 규격)" do
      service = CashReceiptService.new(cert_key: "", corp_num: "1234567890", member_id: "wonbi1")
      envelope = service.send(:build_envelope, "RegistAndIssueCashBill", [
        [ :CERTKEY, "KEY" ], [ :CorpNum, "1234567890" ], [ :UserID, "wonbi1" ],
        [ :Invoice, Barobill::RawXml.new(xml: "<ns:MgtKey>CR1</ns:MgtKey>") ], [ :SMSSendYN, false ]
      ])

      assert_includes envelope, "<ns:Invoice><ns:MgtKey>CR1</ns:MgtKey></ns:Invoice>"
      assert_includes envelope, "<ns:SMSSendYN>false</ns:SMSSendYN>"
    end

    test "CashBillEx 직렬화 — WSDL 실측 순서·Franchise 접두사 태그·TradeDate 포함" do
      service = CashReceiptService.new(cert_key: "", corp_num: "1234567890", member_id: "wonbi1")
      raw = service.send(:cash_bill_ex_xml, "CR1", full_cash_bill)
      children = raw.xml.scan(/<ns:(\w+)>/).flatten

      assert_equal %w[MgtKey FranchiseCorpNum FranchiseMemberID FranchiseCorpName FranchiseCEOName
                      FranchiseAddr FranchiseTel IdentityNum ItemName TradeDate TradeType TradeUsage
                      TradeMethod Amount Tax ServiceCharge], children
      assert_includes raw.xml, "<ns:TradeDate>20261116120000</ns:TradeDate>"
    end

    # ---- MemberService ----

    test "SIMULATED regist_corp — 성공·member_id 반환" do
      service = MemberService.new(cert_key: "")
      tenant = tenants(:one)

      result = service.regist_corp(tenant: tenant, id: "wonbi1", pwd: "password123")

      assert result.success?
      assert_equal "wonbi1", result.value
    end

    test "RegistCorp -32000(기가입) 응답도 성공으로 처리" do
      service = MemberService.new(cert_key: "TESTKEY")
      stub_post_xml(service, <<~XML)
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <RegistCorpResponse xmlns="http://ws.baroservice.com/">
              <RegistCorpResult>-32000</RegistCorpResult>
            </RegistCorpResponse>
          </soap:Body>
        </soap:Envelope>
      XML

      result = service.regist_corp(tenant: tenants(:one), id: "wonbi1", pwd: "password123")

      assert result.success? # -32000 = 기가입(AddUserToCorp 대상) — 온보딩 차단 없음
    end

    private

    def full_cash_bill
      {
        FranchiseCorpNum: "1234567890", FranchiseMemberID: "wonbi1", FranchiseCorpName: "테스트 학원",
        FranchiseCEOName: "김원장", FranchiseAddr: "서울시 강남구", FranchiseTel: "02-1234-5678",
        IdentityNum: "01011112222", TradeDate: "20261116120000", TradeType: "N", TradeUsage: "1",
        TradeMethod: 5, Amount: 250_000, Tax: 0, ServiceCharge: 0,
        ItemName: "2026-11 원비"
      }
    end

    # 실측 응답 구조(testws 스파이크) — GetCashBillStateResult 내부에 BarobillState·NTS 승인번호 자식
    def state_response_xml(state, confirm_num: "", message: nil, variant: "NTSConfirmNum")
      confirm_xml = confirm_num.present? ? "<#{variant}>#{confirm_num}</#{variant}>" : "<NTSConfirmNum/>"
      message_xml = message ? "<NTSConfirmMessage>#{message}</NTSConfirmMessage>" : "<NTSConfirmMessage/>"
      <<~XML
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <GetCashBillStateResponse xmlns="http://ws.baroservice.com/">
              <GetCashBillStateResult>
                <MgtKey>SPIKE20261116001</MgtKey>
                <InvoiceKey/>
                <BarobillState>#{state}</BarobillState>
                <TradeDate>20261116005007</TradeDate>
                <RegistDT>20261116095007</RegistDT>
                <IssueDT>20261116095007</IssueDT>
                <NTSSendDT/>
                <NTSConfirmDT/>
                #{message_xml}
                #{confirm_xml}
              </GetCashBillStateResult>
            </GetCashBillStateResponse>
          </soap:Body>
        </soap:Envelope>
      XML
    end

    # SIMULATED가 실제로 네트워크를 타지 않는지 — post_xml 호출 시 즉시 실패하는 스텁으로 방어
    def forbid_network(service)
      service.singleton_class.class_eval do
        define_method(:post_xml) { |_, _| raise "SIMULATED 모드에서는 외부 호출이 없어야 한다" }
      end
    end
  end
end
