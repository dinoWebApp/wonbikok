# frozen_string_literal: true

module Reminders
  # 리마인더 설정 화면 미리보기용 예시 청구 — 실제 원생 데이터 없이 문구 형태를 보여준다(개인정보 없음).
  # MessageBuilder가 읽는 인터페이스(student_name_snapshot·total_amount·target_month·due_on)만 제공.
  class SampleInvoice
    SAMPLE = {
      student_name_snapshot: "김학부모",
      total_amount: 250_000,
      target_month: Time.zone.now.strftime("%Y-%m"),
      due_on: Time.zone.now.to_date
    }.freeze

    def self.instance
      new
    end

    SAMPLE.each do |name, value|
      define_method(name) { value }
    end
  end
end
