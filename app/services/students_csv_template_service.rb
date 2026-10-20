# 원생 CSV 양식 생성 서비스.
# 양식에는 예시 데이터만 포함하며 실데이터를 담지 않는다(개인정보 원칙).
# 엑셀 호환을 위해 UTF-8 BOM을 붙여 내려준다(CP949 등 인코딩 확장은 P1).
require "csv"

class StudentsCsvTemplateService
  HEADERS = %w[원생명 학년 월\ 원비 납부일 납부유형 상태 보호자명 보호자\ 휴대폰번호].freeze

  # CSV 상태 허용값 → 내부 enum 값
  STATUS_MAP = {
    "재원" => "active",
    "휴원" => "paused",
    "퇴원" => "withdrawn"
  }.freeze

  PAYMENT_TYPE_MAP = {
    "계좌이체" => "bank_transfer",
    "현금" => "cash"
  }.freeze

  class << self
    def template_csv
      CSV.generate(write_headers: true, headers: HEADERS) do |csv|
        csv << [ "홍길동", "초3", "250000", "25", "계좌이체", "재원", "홍어머님", "01012345678" ]
      end
    end

    # 오류행 + 사유를 붙여 같은 양식으로 재업로드 가능한 CSV 생성
    def error_csv(error_rows)
      CSV.generate(write_headers: true, headers: HEADERS + [ "오류 사유" ]) do |csv|
        error_rows.each do |error|
          csv << (error.row_values + [ error.reasons.join(" / ") ])
        end
      end
    end

    def with_bom(csv_string)
      "\uFEFF#{csv_string}"
    end
  end
end
