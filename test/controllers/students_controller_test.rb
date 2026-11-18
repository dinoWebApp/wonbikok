require "test_helper"

class StudentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:one)
    @other_tenant = tenants(:two)
    _t, @user = create_owner_user(tenant: @tenant)
    _t2, @other_user = create_owner_user(tenant: @other_tenant, phone_number: "01077776666")
    log_in(@user)
    @student = create_student_with_guardian(tenant: @tenant, name: "김민준", phone_number: "01011112222")
  end

  # == 인증 게이트 ==
  test "미인증 원생 목록 접근은 로그인으로 리다이렉트된다" do
    delete session_url

    get students_path
    assert_redirected_to new_session_path
  end

  # == TEN-001: 테넌시 격리 ==
  test "TEN-001 타 테넌트 원생 상세 조회는 404다" do
    other_student = students(:other_tenant)

    get student_path(other_student)

    assert_response :not_found
  end

  test "TEN-001 타 테넌트 원생 상태 변경도 404다" do
    other_student = students(:other_tenant)

    patch pause_student_path(other_student)

    assert_response :not_found
    assert_equal "active", other_student.reload.status
  end

  test "TEN-001 목록에는 자기 테넌트 원생만 표시된다" do
    get students_path

    assert_match "김민준", response.body
    assert_no_match "최시우", response.body
  end

  # == TEN-003: 마스킹 ==
  test "TEN-003 목록·상세에 전화 평문이 아닌 마스킹만 표시된다" do
    get students_path

    assert_match "010-****-2222", response.body
    assert_no_match "01011112222", response.body

    get student_path(@student)

    assert_match "010-****-2222", response.body
    assert_no_match "01011112222", response.body
  end

  # == 검색·파라미터 견고성 ==
  test "phone_last4 4자리로 검색된다" do
    get students_path, params: { phone_last4: "2222" }

    assert_match "김민준", response.body
  end

  test "WARNING-5 배열 주입 검색어는 정상 목록으로 처리된다" do
    get students_path, params: { q: [ "김민준" ] }

    assert_response :ok
    assert_match "김민준", response.body
  end

  # == 수동 등록: 중복 확인 → confirm 저장(형제 허용) ==
  test "중복 의심 원생 등록은 422 확인 절차를 요구한다" do
    assert_no_difference "Student.count" do
      post students_path, params: student_params(name: "동생김민준", phone_number: "01011112222")
    end

    assert_response :unprocessable_entity
    assert_match "김민준", response.body
  end

  test "confirm 제출 시 형제 원생 등록이 허용된다" do
    assert_difference "Student.count", 1 do
      post students_path, params: student_params(name: "동생김민서", phone_number: "01011112222", confirm: "1")
    end

    assert_redirected_to students_path
  end

  # WARNING-2: 직접 POST로도 납부일 29는 거절된다(단일 기준 1..28)
  test "WARNING-2 직접 POST의 payment_day 29는 422로 거절된다" do
    assert_no_difference "Student.count" do
      post students_path, params: student_params(name: "경계원생", phone_number: "01010101010", payment_day: "29")
    end

    assert_response :unprocessable_entity
  end

  # == 상태 전이(INV-004) ==
  test "휴원 전이는 ended_on을 기록하고 복원은 해제한다" do
    patch pause_student_path(@student)
    follow_redirect!
    assert_response :ok
    assert_not_nil @student.reload.ended_on

    patch restore_student_path(@student)
    follow_redirect!
    assert_response :ok
    assert_nil @student.reload.ended_on
    assert_includes Student.active.pluck(:id), @student.id
  end

  # == CSV 일괄 등록 ==
  test "정상 CSV 업로드는 원생을 반영한다" do
    assert_difference "Student.count", 1 do
      post import_students_path, params: { file: csv_upload(<<~CSV) }
        원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
        정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
      CSV
    end

    assert_response :ok
  end

  # F2 수용조건: 부분 실패 시 정상행 보존 + 오류 422
  test "CSV 부분 실패 시 정상행만 반영되고 422로 응답한다" do
    post import_students_path, params: { file: csv_upload(<<~CSV) }
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
      나쁜행,초2,abc,35,손금,대기,나어머님,01099999999
    CSV

    assert_response :unprocessable_entity
    assert_equal 1, @tenant.students.reload.where(name: "정다은").count
  end

  # CRITICAL-1: 중복 의심 행은 오류행 전환(동일 파일 2회 업로드 → 생성 0건)
  test "CRITICAL-1 동일 파일 재업로드 시 전 행이 중복 의심 오류가 된다" do
    csv = <<~CSV
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
    CSV

    post import_students_path, params: { file: csv_upload(csv) }
    assert_response :ok

    assert_no_difference "Student.count" do
      post import_students_path, params: { file: csv_upload(csv) }
    end
    assert_response :unprocessable_entity
    assert_match "중복 의심", response.body
  end

  # BLOCKER-1: 1MB 초과 업로드는 422로 차단된다
  test "BLOCKER-1 1MB 초과 파일은 422로 차단된다" do
    big_csv = "원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호\n" +
              ("초과행,초1,180000,15,계좌이체,재원,초과어머님,01055556666\n" * 20_000)

    assert_no_difference "Student.count" do
      post import_students_path, params: { file: csv_upload(big_csv) }
    end

    assert_response :unprocessable_entity
    # BUG-1 회귀: 로케일 키가 errors: 하위에 있어야 Translation missing이 노출되지 않는다
    assert_no_match "Translation missing", response.body
    assert_match "파일이 너무 큽니다", response.body
  end

  # WARNING-5: 파일 필드 문자열 변조는 422
  test "파일 필드가 문자열이면 422로 응답한다" do
    post import_students_path, params: { file: "변조된값" }

    assert_response :unprocessable_entity
    assert_no_match "Translation missing", response.body
    assert_match "CSV 파일을 선택해 주세요", response.body
  end

  test "파일 미선택 업로드는 422로 응답한다" do
    post import_students_path, params: {}

    assert_response :unprocessable_entity
    assert_no_match "Translation missing", response.body
    assert_match "CSV 파일을 선택해 주세요", response.body
  end

  # BLOCKER-1: 오류내역 캐시 저장·만료(캐시 스토어 교체로 검증 — 리뷰어 메모 반영)
  test "오류내역은 테넌트별 캐시 키로 저장되고 만료 시 재업로드를 안내한다" do
    with_memory_cache do
      post import_students_path, params: { file: csv_upload(<<~CSV) }
        이름,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
        정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
      CSV
      assert_response :unprocessable_entity

      # 키가 테넌트별로 분리되어 발급된다(TEN-001)
      assert_includes session[:csv_import_errors_key], "csv_import_errors:#{@tenant.id}:"

      get import_errors_students_path
      assert_response :ok
      assert_match "01055556666", response.body

      # 만료(캐시 소멸) 후에는 정보 없이 재업로드 안내만 제공한다(BUG-1 회귀 포함)
      Rails.cache.clear
      get import_errors_students_path
      assert_redirected_to import_students_path
      follow_redirect!
      assert_no_match "01055556666", response.body
      assert_no_match "Translation missing", response.body
      assert_match "오류 내역이 만료되었거나 없습니다", response.body
    end
  end

  # BUG-2: 오류내역 키가 없는 세션의 직접 접근은 500(ArgumentError)이 아닌 만료 안내 리다이렉트
  test "오류내역 키가 없는 세션의 직접 접근은 500이 아닌 만료 안내 리다이렉트다" do
    log_in(@user) # 새 세션 — csv_import_errors_key 없음

    get import_errors_students_path

    assert_redirected_to import_students_path
    follow_redirect!
    assert_no_match "01055556666", response.body
    assert_no_match "Translation missing", response.body
    assert_match "오류 내역이 만료되었거나 없습니다", response.body
  end

  # TEN-001: 새 세션(타 브라우저·타 계정)으로는 오류내역 키가 조회되지 않는다
  test "타 테넌트 세션으로 오류내역 키에 접근할 수 없다" do
    with_memory_cache do
      # 온보딩 게이트(W1 후속) 대상 회피 — 본 테스트는 TEN-001 캐시 키 격리 검증이 목적
      @other_tenant.update!(onboarding_step: Tenant::ONBOARDING_FINAL_STEP)
      post import_students_path, params: { file: csv_upload(<<~CSV) }
        이름,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
        정다은,초1,180000,15,계좌이체,재원,정어머님,01055556666
      CSV

      reset!
      log_in(@other_user)

      # 새 세션에는 키가 없어 오류내역 데이터가 노출되지 않아야 한다(BUG-2 수정: 만료 안내 리다이렉트)
      get import_errors_students_path
      assert_redirected_to import_students_path
      follow_redirect!
      assert_no_match "01055556666", response.body
    end
  end

  # CSV 양식 다운로드: 실데이터 미포함(TEN-003)
  test "CSV 양식에는 예시 데이터만 있고 실 원생 데이터가 없다" do
    get import_template_students_path

    assert_response :ok
    assert_match "원생명", response.body
    assert_no_match "김민준", response.body
    assert_no_match "01011112222", response.body
  end

  # == SUB-001: 플랜 원생 수 상한 초과 시 신규 등록 차단(W4 F8) ==
  test "SUB-001 상한 도달 시 원생 등록은 422로 차단되고 기존 원생은 유지된다" do
    @tenant.update!(onboarding_step: Tenant::ONBOARDING_FINAL_STEP)
    subscription = Subscription.create!(
      tenant: @tenant, plan: :light, status: :active, # light 상한 30명
      trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago,
      current_period_start: 10.days.ago, current_period_end: 20.days.from_now
    )
    # setup 원생(@student) + fixture 재원 원생 포함 재원 30명 채우기
    28.times do |i|
      create_student_with_guardian(tenant: @tenant, name: "채움원생#{i}",
                                   phone_number: format("0105555%04d", i))
    end
    assert_equal 30, @tenant.students.active.count

    assert_no_difference "Student.count" do
      post students_path, params: student_params(name: "초과원생", phone_number: "01088887777", confirm: "1")
    end

    assert_response :unprocessable_entity
    assert_not_nil flash[:alert] # 상한 안내(문구 키는 3-S ko.yml 병합)
    assert_equal 30, subscription.reload.tenant.students.active.count # 기존 원생 유지
  end

  test "SUB-001 휴원 원생은 상한 집계에서 제외된다(재원 기준)" do
    @tenant.update!(onboarding_step: Tenant::ONBOARDING_FINAL_STEP)
    Subscription.create!(
      tenant: @tenant, plan: :light, status: :active,
      trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago,
      current_period_start: 10.days.ago, current_period_end: 20.days.from_now
    )
    27.times do |i|
      create_student_with_guardian(tenant: @tenant, name: "재원채움#{i}",
                                   phone_number: format("0106666%04d", i))
    end
    paused = create_student_with_guardian(tenant: @tenant, name: "휴원원생",
                                          phone_number: "01077770001")
    paused.update!(status: :paused) # 재원 29 + 휴원 1 = 상한(30) 미도달
    assert_equal 29, @tenant.students.active.count

    assert_difference "Student.count", 1 do
      post students_path, params: student_params(name: "신규원생", phone_number: "01088886666", confirm: "1")
    end

    assert_redirected_to students_path
  end

  test "SUB-001 상한 도달 시 CSV 등록은 422로 차단된다(C-1)" do
    @tenant.update!(onboarding_step: Tenant::ONBOARDING_FINAL_STEP)
    Subscription.create!(
      tenant: @tenant, plan: :light, status: :active,
      trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago,
      current_period_start: 10.days.ago, current_period_end: 20.days.from_now
    )
    28.times do |i| # setup 원생 + fixture 재원 원생 포함 30명 도달
      create_student_with_guardian(tenant: @tenant, name: "채움원생#{i}",
                                   phone_number: format("0105555%04d", i))
    end

    post import_students_path, params: { file: csv_upload(<<~CSV) }
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      초과원생,초1,180000,15,계좌이체,재원,초과어머님,01088887777
    CSV

    assert_response :unprocessable_entity
    assert_match "플랜 상한", response.body
    assert_nil @tenant.students.reload.find_by(name: "초과원생")
  end

  test "SUB-001 잔여 1 슬롯에 2행 CSV는 1성공/1오류행 경계로 처리된다(C-1)" do
    @tenant.update!(onboarding_step: Tenant::ONBOARDING_FINAL_STEP)
    Subscription.create!(
      tenant: @tenant, plan: :light, status: :active,
      trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago,
      current_period_start: 10.days.ago, current_period_end: 20.days.from_now
    )
    27.times do |i| # 재원 29명 — 잔여 1
      create_student_with_guardian(tenant: @tenant, name: "재원채움#{i}",
                                   phone_number: format("0106666%04d", i))
    end

    post import_students_path, params: { file: csv_upload(<<~CSV) }
      원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
      마지막원생,초1,180000,15,계좌이체,재원,마지어머님,01055550001
      초과원생,초2,190000,16,현금,재원,초과어머님,01055550002
    CSV

    assert_response :unprocessable_entity # 오류행 존재 시 결과 화면 422(기존 부분 실패 규약 — 정상행은 보존)
    assert_equal 30, @tenant.students.active.count
    assert_not_nil @tenant.students.find_by(name: "마지막원생")
    assert_nil @tenant.students.find_by(name: "초과원생")
    assert_match "플랜 원생 수 상한", response.body
  end

  test "SUB-001 구독이 없는 레거시 계정은 상한 없이 등록된다" do
    assert_nil Subscription.find_by(tenant_id: @tenant.id)

    assert_difference "Student.count", 1 do
      post students_path, params: student_params(name: "레거시원생", phone_number: "01099990001", confirm: "1")
    end

    assert_redirected_to students_path
  end

  # C-1 회귀 고정: 레거시 계정(잔여 슬롯 nil)의 CSV 등록도 상한 검사 없이 통과한다
  test "SUB-001 구독이 없는 레거시 계정의 CSV 등록은 상한 없이 처리된다" do
    assert_nil Subscription.find_by(tenant_id: @tenant.id) # 잔여 슬롯 미산정 — 가드 비대상

    assert_difference "Student.count", 1 do
      post import_students_path, params: { file: csv_upload(<<~CSV) }
        원생명,학년,월 원비,납부일,납부유형,상태,보호자명,보호자 휴대폰번호
        레거시CSV원생,초1,180000,15,계좌이체,재원,레거시어머님,01099998888
      CSV
    end

    assert_response :ok
    assert_not_nil @tenant.students.reload.find_by(name: "레거시CSV원생")
  end

  private

  def csv_upload(text)
    Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "students.csv")
  end

  def student_params(name:, phone_number:, confirm: nil, payment_day: "15")
    {
      student: {
        name: name, grade: "초1", monthly_fee: "180000", payment_day: payment_day,
        guardians_attributes: { "0" => { name: "#{name} 어머님", phone_number: phone_number } }
      },
      confirm: confirm
    }.compact
  end
end
