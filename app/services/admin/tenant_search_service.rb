# 이용자(원장) 통합 검색 (PRD 12장 A2).
#
# v1.0 검색 대상: 상호(name) · 사업자등록번호(business_number) · 내부 교습소 ID(id).
# 휴대폰번호 검색은 users.phone_number가 Active Record Encryption으로 암호화되어
# 부분 일치 조회가 불가능하고(deterministic은 동일값 전체 일치만 가능), phone_last4 보조 컬럼이
# 없어 v1.0에서 축소했다 — 후속 과제(전용 인덱스 컬럼 도입 시 확장).
#
# TEN-001: 본 서비스는 관리자 전용 전체 테넌트 조회이며, 결과 표시 마스킹은
# Admin::BaseController의 helper(ADM-002)로 수행한다.
module Admin
  class TenantSearchService
    attr_reader :query

    def initialize(scope: Tenant.all)
      @scope = scope
    end

    # 통합 검색 — 상호/사업자번호 부분 일치 + ID 완전 일치(숫자 입력 시).
    # 빈 쿼리는 전체 목록(최근 가입순)을 반환한다.
    def call(query)
      @query = query.to_s.strip
      return @scope.order(created_at: :desc, id: :desc) if @query.blank?

      # SQLite LIKE는 기본 이스케이프 문자가 없어 ESCAPE '\' 지정 필요 — \%·\_를 리터럴로 취급
      relation = @scope.where(
        "name LIKE :q ESCAPE '\\' OR business_number LIKE :q ESCAPE '\\'", q: "%#{escape_like(@query)}%"
      )
      relation = relation.or(@scope.where(id: @query.to_i)) if @query.match?(/\A\d+\z/)
      relation.order(created_at: :desc, id: :desc)
    end

    private

    # LIKE 와일드카드(% _) 이스케이프 — 사용자 입력 패턴 주입 방지
    def escape_like(value)
      value.gsub(/[\\%_]/) { |char| "\\#{char}" }
    end
  end
end
