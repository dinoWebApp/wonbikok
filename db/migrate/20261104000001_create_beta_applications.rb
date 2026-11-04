class CreateBetaApplications < ActiveRecord::Migration[8.1]
  # 베타(파일럿) 신청 — PRD 13.6 (랜딩 전환 지점)
  # Rule ID: TEN-002(주민번호 등 불필요 항목 수집 금지 — 주민번호·IP·UA 필드 없음),
  #          TEN-003(연락처 Active Record Encryption 암호화), TEN-006 준용(기록 최소화)
  def change
    create_table :beta_applications do |t|
      t.string :name, null: false                  # 원장 이름
      t.string :title, null: false                 # 호칭 키: principal / teacher / other
      t.string :contact_type, null: false          # 연락 수단: email / phone
      t.string :contact_value, null: false         # 연락처 — 암호화 저장(TEN-003)
      t.string :academy_type, null: false          # 교습소 유형 키: academy / study_room / other
      t.string :student_count_range                # 원생 수 구간(선택)
      t.text :current_method                       # 현재 원비 관리 방식(선택)
      t.text :pain_point                           # 가장 불편한 업무(선택)
      t.boolean :terms_agreed, default: false, null: false      # 개인정보 수집·이용 동의(필수)
      t.boolean :marketing_agreed, default: false, null: false  # 마케팅 수신 동의(선택·분리)

      t.timestamps
    end

    # 중복 신청 최소 식별(13.6) — contact 기준 유니크 인덱스.
    # contact_value는 deterministic 암호화로 동등성 검색 가능(모델 encrypts 참조).
    # 유니크 제약으로 동시 제출(더블클릭 등) 경쟁 조건에서도 중복 레코드 생성 차단
    add_index :beta_applications, [ :contact_type, :contact_value ], unique: true
  end
end
