require "test_helper"
require "csv"

class StudentsCsvImportServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:one)
  end

  test "정상 행은 모두 반영된다" do
    upload = csv_upload(<<~CSV)
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
      한지호,중2,320000,20,현금,재원,한아버님,01077778888
    CSV

    result = StudentsCsvImportService.new(tenant: @tenant, upload: upload).call

    assert_equal 2, result.success_count
    assert_empty result.errors
    assert_equal "정다은", @tenant.students.reload.find_by(name: "정다은").name
    assert_equal "6666", @tenant.students.find_by(name: "정다은").primary_guardian.phone_last4
  end

  # F2 수용조건: 행 단위 부분 실패 — 정상행 보존 + 오류행 사유 수집
  test "부분 실패 시 정상행은 보존되고 오류행 사유가 수집된다" do
    upload = csv_upload(<<~CSV)
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
      나쁜행,초2,abc,35,손금,대기,나어머님,01099999999
    CSV

    result = StudentsCsvImportService.new(tenant: @tenant, upload: upload).call

    assert_equal 1, result.success_count
    assert_equal 1, result.errors.size
    assert_equal 3, result.errors.first.line
    assert result.errors.first.reasons.join.present?
    assert_not_nil @tenant.students.reload.find_by(name: "정다은")
    assert_nil @tenant.students.find_by(name: "나쁜행")
  end

  # PAY-DAY 경계: CSV에서도 1..28 강제
  test "납부일 29는 거절되고 28은 허용된다" do
    upload = csv_upload(<<~CSV)
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      일일이,초1,180000,28,계좌이체,재원,일어머님,01012123434
      구구구,초1,180000,29,계좌이체,재원,구어머님,01056567878
    CSV

    result = StudentsCsvImportService.new(tenant: @tenant, upload: upload).call

    assert_equal 1, result.success_count
    assert_equal 1, result.errors.size
    assert_not_nil @tenant.students.reload.find_by(name: "일일이")
    assert_nil @tenant.students.find_by(name: "구구구")
  end

  # CRITICAL-1: 기존 원생과 중복 의심인 행은 오류행으로 전환된다
  test "CRITICAL-1 기존 원생과 동일 보호자 전화 행은 오류행으로 전환된다" do
    create_student_with_guardian(tenant: @tenant, name: "김민준", phone_number: "01011112222")
    upload = csv_upload(<<~CSV)
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      김민준2,초3,250000,25,계좌이체,재원,김어머님,01011112222
    CSV

    result = StudentsCsvImportService.new(tenant: @tenant, upload: upload).call

    assert_equal 0, result.success_count
    assert_includes result.errors.first.reasons.join, "중복 의심"
    assert_includes result.errors.first.reasons.join, "김민준"
    assert_equal 1, @tenant.students.reload.where(name: [ "김민준", "김민준2" ]).count
  end

  # BLOCKER-1 회귀 방어: 헤더 오타 시 전 행 오류 수집(500/유실 없음)
  test "헤더 오타 시 전 행이 행번호와 함께 오류 수집된다" do
    upload = csv_upload(<<~CSV)
      이름,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
      한지호,중2,320000,20,현금,재원,한아버님,01077778888
    CSV

    result = StudentsCsvImportService.new(tenant: @tenant, upload: upload).call

    assert_equal 0, result.success_count
    assert_equal 2, result.errors.size
    assert_equal [ 2, 3 ], result.errors.map(&:line)
    assert_equal 0, @tenant.students.reload.where(name: %w[정다은 한지호]).count
  end

  # 동일 파일 내 중복도 포착(행 단위 즉시 반영 + 메모리 타깃 재조회)
  test "동일 파일 내 중복 행도 오류행으로 전환된다" do
    upload = csv_upload(<<~CSV)
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      쌍둥이,초1,180000,15,계좌이체,재원,쌍어머님,01044445555
      쌍둥이2,초1,180000,15,계좌이체,재원,쌍어머님,01044445555
    CSV

    result = StudentsCsvImportService.new(tenant: @tenant, upload: upload).call

    assert_equal 1, result.success_count
    assert_includes result.errors.first.reasons.join, "중복 의심"
  end

  test "UTF-8이 아닌 입력은 인코딩 오류 1건으로 수집된다" do
    upload = StringIO.new("이름,학년\r\n".encode("CP949"))

    result = StudentsCsvImportService.new(tenant: @tenant, upload: upload).call

    assert_equal 0, result.success_count
    assert_equal 1, result.errors.size
    assert_includes result.errors.first.reasons.join, "인코딩"
  end

  private

  def csv_upload(text)
    StringIO.new(text)
  end
end
