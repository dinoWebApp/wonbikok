# 원생 CSV 일괄 등록 서비스.
# 행 단위로 파싱·검증하고 정상행은 즉시 반영(Student+대표 Guardian), 오류행은
# 행번호+사유를 수집해 재업로드(2차 업로드)에 사용한다(F2 수용조건).
# 입력 파일은 읽기 직후 메모리에서만 사용하고 임시 보관하지 않는다.
require "csv"

class StudentsCsvImportService
  ImportError = Struct.new(:line, :row_values, :reasons, keyword_init: true)
  Result = Struct.new(:success_count, :errors, keyword_init: true)

  PAYMENT_DAY_RANGE = Student::PAYMENT_DAY_RANGE

  def initialize(tenant:, upload:)
    @tenant = tenant
    @upload = upload
  end

  def call
    text = read_as_utf8
    return Result.new(success_count: 0, errors: [ text ]) if text.is_a?(ImportError)

    success_count = 0
    errors = []
    duplicate_finder = GuardianDuplicateFinder.new(@tenant)

    CSV.parse(text, headers: true, skip_blanks: true).each_with_index do |row, index|
      line = index + 2 # 헤더가 1행
      error = import_row(row, line, duplicate_finder)
      error ? errors << error : success_count += 1
    end

    Result.new(success_count: success_count, errors: errors)
  end

  private

  def read_as_utf8
    raw = @upload.read
    raw = raw.force_encoding("UTF-8").delete_prefix("\uFEFF")
    return encoding_error(raw) unless raw.valid_encoding?

    raw
  rescue ArgumentError
    encoding_error(nil)
  end

  def encoding_error(_)
    ImportError.new(line: 0, row_values: [], reasons: [ I18n.t("students.import.errors.encoding") ])
  end

  def import_row(row, line, duplicate_finder)
    values = StudentsCsvTemplateService::HEADERS.map { |header| row[header].to_s.strip }
    reasons = validate(values)
    return ImportError.new(line: line, row_values: values, reasons: reasons) if reasons.any?

    # 수동 등록과 동일한 기준의 중복 검사(CRITICAL-1): 동일 보호자 전화·유사 이름
    conflicts = duplicate_finder.conflicts_with(name: values.first, phone_number: values.last)
    if conflicts.any?
      return ImportError.new(
        line: line, row_values: values,
        reasons: [ I18n.t("students.import.errors.duplicate_suspect", name: conflicts.first.name) ]
      )
    end

    student = build_student(values)
    begin
      ActiveRecord::Base.transaction { student.save! }
      nil # 성공: 오류 없음
    rescue ActiveRecord::RecordInvalid
      ImportError.new(line: line, row_values: values, reasons: student.errors.full_messages)
    end
  end

  def validate(values)
    name, _grade, fee, payment_day, payment_type, status, guardian_name, phone = values
    reasons = []
    reasons << I18n.t("students.import.errors.required_name") if name.blank?
    reasons << I18n.t("students.import.errors.required_fee") unless fee.match?(/\A\d+\z/)
    unless payment_day.match?(/\A\d+\z/) && PAYMENT_DAY_RANGE.cover?(payment_day.to_i)
      reasons << I18n.t("students.import.errors.payment_day")
    end
    unless StudentsCsvTemplateService::PAYMENT_TYPE_MAP.key?(payment_type)
      reasons << I18n.t("students.import.errors.payment_type")
    end
    unless StudentsCsvTemplateService::STATUS_MAP.key?(status)
      reasons << I18n.t("students.import.errors.status")
    end
    reasons << I18n.t("students.import.errors.required_guardian_name") if guardian_name.blank?
    unless phone.gsub(/[^0-9]/, "").match?(/\A01[016789]\d{7,8}\z/)
      reasons << I18n.t("students.import.errors.phone")
    end
    reasons
  end

  def build_student(values)
    name, grade, fee, payment_day, payment_type, status, guardian_name, phone = values

    @tenant.students.build(
      name: name,
      grade: grade,
      monthly_fee: fee.to_i,
      payment_day: payment_day.to_i,
      payment_type: StudentsCsvTemplateService::PAYMENT_TYPE_MAP.fetch(payment_type),
      status: StudentsCsvTemplateService::STATUS_MAP.fetch(status)
    ).tap do |student|
      student.guardians.build(name: guardian_name, phone_number: phone)
    end
  end
end
