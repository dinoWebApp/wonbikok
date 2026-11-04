require "test_helper"

class BetaApplicationTest < ActiveSupport::TestCase
  # fixtures 미사용 — contact_value가 encrypts 컬럼이라 모델 API로만 생성한다(TEN-003,
  # test_helper의 create_owner_user 선례와 동일 원칙)

  # PRD 13.6 필수 항목: 이름·호칭·연락 수단·연락처·교습소 유형·개인정보 동의
  def valid_attributes(contact_type: "email", contact_value: "pilot@example.com")
    {
      name: "김원장",
      title: "principal",
      contact_type: contact_type,
      contact_value: contact_value,
      academy_type: "academy",
      terms_agreed: true
    }
  end

  # --- 정상 케이스 ---

  test "필수 항목만으로 신청을 생성할 수 있다" do
    application = BetaApplication.create!(valid_attributes)

    assert application.persisted?
    assert_equal "김원장", application.name
    assert_equal "principal", application.title
    assert_equal "academy", application.academy_type
  end

  test "marketing_agreed는 기본 false로 저장된다(마케팅 수신은 선택)" do
    application = BetaApplication.create!(valid_attributes)

    assert_equal false, application.marketing_agreed
  end

  test "marketing_agreed true 저장과 선택 항목(원생 수·관리 방식·불편 업무) 저장이 가능하다" do
    application = BetaApplication.create!(valid_attributes.merge(
      marketing_agreed: true,
      student_count_range: "1_15",
      current_method: "엑셀",
      pain_point: "매달 통장 대조"
    ))

    assert_equal true, application.marketing_agreed
    assert_equal "1_15", application.student_count_range
    assert_equal "엑셀", application.current_method
    assert_equal "매달 통장 대조", application.pain_point
  end

  # --- 필수 항목 누락(예외) — PRD 13.6 ---

  test "필수 항목 누락별로 무효하다" do
    required_keys = %i[name title contact_type contact_value academy_type terms_agreed]

    required_keys.each do |key|
      attrs = valid_attributes.merge(key => key == :terms_agreed ? false : nil)
      application = BetaApplication.new(attrs)

      refute application.valid?, "#{key} 누락이 허용되어서는 안 됩니다"
      assert application.errors[key].present?, "#{key} 오류 메시지가 없습니다"
    end
  end

  test "호칭·연락 수단·교습소 유형에 정의되지 않은 키는 무효하다" do
    assert_not BetaApplication.new(valid_attributes.merge(title: "boss")).valid?
    assert_not BetaApplication.new(valid_attributes.merge(contact_type: "kakao")).valid?
    assert_not BetaApplication.new(valid_attributes.merge(academy_type: "cafe")).valid?
  end

  test "원생 수 구간에 정의되지 않은 키는 무효하고, 빈 값은 허용된다(선택 항목)" do
    assert_not BetaApplication.new(valid_attributes.merge(student_count_range: "1000_plus")).valid?
    assert BetaApplication.new(valid_attributes).valid? # student_count_range 없음
  end

  # --- 연락처 형식·정규화 ---

  test "이메일 형식이 올바르지 않으면 무효하다" do
    [ "no-at-sign", "a b@example.com", "trailing@@double" ].each do |value|
      application = BetaApplication.new(valid_attributes(contact_value: value))

      refute application.valid?, "잘못된 이메일 #{value}가 허용되어서는 안 됩니다"
      assert application.errors[:contact_value].present?
    end
  end

  test "전화 형식이 올바르지 않으면 무효하다" do
    [ "12345", "02-123-4567", "0101234567890" ].each do |value|
      application = BetaApplication.new(valid_attributes(contact_type: "phone", contact_value: value))

      refute application.valid?, "잘못된 전화번호 #{value}가 허용되어서는 안 됩니다"
      assert application.errors[:contact_value].present?
    end
  end

  test "전화 정규화: 하이픈·공백을 제거한 번호로 저장된다" do
    application = BetaApplication.create!(valid_attributes(contact_type: "phone", contact_value: "010-1234-5678"))

    assert_equal "01012345678", application.contact_value
  end

  test "이메일은 좌우 공백을 제거한 값으로 저장된다" do
    application = BetaApplication.create!(valid_attributes(contact_value: " pilot@example.com "))

    assert_equal "pilot@example.com", application.contact_value
  end

  # --- TEN-003: 연락처 암호화 저장 ---

  test "TEN-003 contact_value는 DB에 평문이 아닌 암호문으로 저장된다" do
    application = BetaApplication.create!(valid_attributes)
    raw = BetaApplication.connection.select_value(
      BetaApplication.sanitize_sql_array([ "SELECT contact_value FROM beta_applications WHERE id = ?", application.id ])
    )

    assert_not_includes raw, "pilot@example.com"
  end

  test "TEN-003 저장한 연락처를 평문으로 복원한다" do
    application = BetaApplication.create!(valid_attributes)

    assert_equal "pilot@example.com", application.reload.contact_value
  end

  test "TEN-003 deterministic 암호화로 동일 연락처 조회(with_contact)가 가능하다" do
    BetaApplication.create!(valid_attributes)

    assert BetaApplication.with_contact("email", "pilot@example.com").exists?,
           "동일 평문이 조회되지 않으면 중복 신청 감지가 동작하지 않습니다"
    assert_not BetaApplication.with_contact("email", "other@example.com").exists?
    assert_not BetaApplication.with_contact("phone", "pilot@example.com").exists?,
               "연락 수단이 다르면 동일한 것으로 취급하지 않는다"
  end

  # --- 중복 제약(멱등성 — WARNING-2 유니크 인덱스) ---

  test "동일 연락 수단+연락처 두 번째 생성은 검증을 통과하더라도 DB 유니크 제약으로 RecordNotUnique가 발생한다" do
    BetaApplication.create!(valid_attributes)

    assert_raises(ActiveRecord::RecordNotUnique) do
      # 모델에 중복 검증이 없으므로 valid?는 통과 → INSERT에서 유니크 인덱스가 차단(동시 제출 경합 방어)
      BetaApplication.create!(valid_attributes)
    end
  end

  test "다른 연락처는 유니크 제약과 무관하게 생성된다" do
    BetaApplication.create!(valid_attributes)

    assert_nothing_raised do
      BetaApplication.create!(valid_attributes(contact_value: "another@example.com"))
    end
  end

  # --- TEN-002: 불필요·민감 항목 수집 금지 (PRD 13.6 + 22.1) ---

  test "TEN-002 주민번호·생년월일·IP 등 금지 항목 컬럼이 없다" do
    forbidden = %w[resident_number ssn birth_date birth ip_address user_agent referrer]

    forbidden.each do |column|
      assert_not_includes BetaApplication.column_names, column,
                          "금지 항목 #{column} 컬럼이 존재하면 TEN-002 위반입니다"
    end
  end

  test "TEN-002 수집 컬럼은 13.6 폼 항목과 정확히 일치한다(초과 수집 없음)" do
    expected = %w[id name title contact_type contact_value academy_type
                  student_count_range current_method pain_point
                  terms_agreed marketing_agreed created_at updated_at]

    assert_equal expected.sort, BetaApplication.column_names.sort
  end
end
