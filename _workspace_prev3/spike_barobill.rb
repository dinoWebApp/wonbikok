# F5 스파이크 — 바로빌 테스트서버(testws) 실호출 1회 검증 (어댑터 파라미터 정합화 게이트)
# 실행: BAROBILL_LIVE=1 bin/rails runner _workspace/spike_barobill.rb
# 더미 사업자정보 사용(테스트 서버 전용 — 운영과 무관, 실과금·국세청 전송 없음)
require "securerandom"

INFO = {
  corp_num: "2208100020",
  corp_name: "원비콕테스트",
  ceo_name: "스파이크테스트",
  addr: "서울특별시 테스트구 테스트로 1",
  biz_type: "서비스업",
  biz_category: "교습소",
  tel: "0212345678",
  email: "spike@example.com"
}.freeze

MEMBER_ID = "wbspike01"
MEMBER_PWD = "Spike#{SecureRandom.alphanumeric(10)}"
MGT_KEY = "SPIKE20261116001"

def show(label, result)
  puts format("%-14s success=%-5s code=%-12s value=%s message=%s",
              label, result.success?, result.code.inspect, result.value.inspect[0, 120], result.message.inspect)
  result
end

TenantStub = Struct.new(:business_number, :name, :owner_name, :address, :biz_type,
                        :business_type, :biz_tel, :email, keyword_init: true)
tenant = TenantStub.new(
  business_number: INFO[:corp_num], name: INFO[:corp_name], owner_name: INFO[:ceo_name],
  address: INFO[:addr], biz_type: INFO[:biz_type], business_type: INFO[:biz_category],
  biz_tel: INFO[:tel], email: INFO[:email]
)

cert_key = Barobill::BaseService.resolve_cert_key
puts "env=#{Rails.env} cert_key=#{cert_key.present? ? '설정됨' : '공백(SIMULATED)'} host=#{Rails.env.production? ? 'ws(운영!)' : 'testws'} BAROBILL_LIVE=#{ENV['BAROBILL_LIVE'].inspect}"

member = Barobill::MemberService.new(cert_key: cert_key)
regist = show("RegistCorp", member.regist_corp(tenant: tenant, id: MEMBER_ID, pwd: MEMBER_PWD))
puts "※ RegistCorp 실패 시: code가 파라미터 정합(태그명 BizClass vs BizCategory 등)·엔드포인트(SVC 경로) 문제일 수 있음 — 03_implementation §3 대조"

receipt = Barobill::CashReceiptService.new(
  cert_key: cert_key, corp_num: INFO[:corp_num], member_id: MEMBER_ID
)

cash_bill = {
  FranchiseCorpNum: INFO[:corp_num], FranchiseMemberID: MEMBER_ID,
  FranchiseCorpName: INFO[:corp_name], FranchiseCEOName: INFO[:ceo_name],
  FranchiseAddr: INFO[:addr], FranchiseTel: INFO[:tel],
  IdentityNum: "01000001234", HP: "01000001234",
  TradeDate: Time.current.strftime("%Y%m%d%H%M%S"),
  TradeType: "N", TradeUsage: "1", TradeMethod: 5,
  Amount: 10_000, Tax: 0, ServiceCharge: 0, ItemName: "F5 스파이크 테스트"
}
issue = show("RegistAndIssue", receipt.regist_and_issue(mgt_key: MGT_KEY, cash_bill: cash_bill))

if issue.success?
  6.times do |i|
    sleep 3
    st = show("State##{i}", receipt.state(mgt_key: MGT_KEY))
    break if st.success? && st.value.is_a?(Hash) && st.value[:barobill_state] == 3000
  end
end

puts "스파이크 종료 — 결과를 08_run_report.md·memory에 기록합니다."
