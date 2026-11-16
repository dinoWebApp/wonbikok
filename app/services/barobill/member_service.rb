# frozen_string_literal: true

module Barobill
  # 바로빌 회원사(원장) 자동 가입 어댑터(PRD 10.2).
  # 흐름: CheckCorpIsMember → 미가입이면 RegistCorp(예외 -32000 = 기가입 → 성공 간주).
  # RegistCorp 필수 수집: CorpNum·CEOName·CorpName·Addr·BizType(업태)·TEL·Email + 계정(ID/PWD 6~20자).
  class MemberService < BaseService
    ALREADY_MEMBER_CODE = -32_000 # 기가입(AddUserToCorp 대상) — 온보딩 차단 없음

    def initialize(cert_key:)
      super(cert_key: cert_key)
    end

    # 회원사 여부 확인(CheckCorpIsMember — 1=가입, 그 외 미가입/오류)
    def corp_member?(corp_num:)
      return true if simulated?

      result = call("CheckCorpIsMember", [
        [ :CERTKEY, cert_key ],
        [ :CorpNum, corp_num.to_s ]
      ])
      result.success? && result.value.to_i == 1
    end

    # 회원사 자동 가입(RegistCorp) → Result(value: member_id) / -32000도 success로 반환.
    # 실패 시 온보딩 차단 없음 — 호출자(온보딩)는 결과 무시하고 진행 가능.
    def regist_corp(tenant:, id:, pwd:)
      member_id = id.to_s
      fields = [
        [ :CERTKEY, cert_key ],
        [ :CorpNum, tenant.business_number.to_s ],
        [ :CorpName, tenant.name.to_s ],
        [ :CEOName, tenant.owner_name.to_s ],
        [ :Addr, tenant.address.to_s ],
        [ :BizType, tenant.biz_type.to_s ],
        [ :BizCategory, tenant.business_type.to_s ],
        [ :TEL, tenant.biz_tel.to_s ],
        [ :Email, tenant.email.to_s ],
        [ :ID, member_id ],
        [ :PWD, pwd.to_s ]
      ]

      result = call("RegistCorp", fields)
      return Result.ok(value: member_id) if simulated?

      # -32000 = 기가입(CheckCorpIsMember 누락·AddUserToCorp 대상) — 온보딩 차단 없음, 성공 간주
      return Result.ok(value: member_id) if result.success? && (result.value.to_i == 1 || result.code == ALREADY_MEMBER_CODE)
      return Result.ok(value: member_id) if !result.success? && result.code == ALREADY_MEMBER_CODE

      result
    end

    def simulated_value_for(method_name)
      "1" if %w[CheckCorpIsMember RegistCorp].include?(method_name)
    end
  end
end
