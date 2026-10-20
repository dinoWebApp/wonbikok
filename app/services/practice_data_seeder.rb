# 연습 모드용 샘플 원생 10명 + 대표 보호자 생성 서비스.
# 연습 모드에서는 외부 발송·발행이 발생하지 않는다(F1 수용조건).
class PracticeDataSeeder
  SAMPLES = [
    { name: "김서연", grade: "초3", fee: 250_000, status: :active, type: :bank_transfer },
    { name: "이준호", grade: "초5", fee: 280_000, status: :active, type: :bank_transfer },
    { name: "박지우", grade: "중1", fee: 320_000, status: :active, type: :bank_transfer },
    { name: "최도윤", grade: "초2", fee: 230_000, status: :active, type: :cash },
    { name: "정하은", grade: "중2", fee: 350_000, status: :active, type: :bank_transfer },
    { name: "강시우", grade: "초4", fee: 260_000, status: :paused, type: :bank_transfer },
    { name: "윤소현", grade: "초6", fee: 300_000, status: :active, type: :cash },
    { name: "임재원", grade: "중3", fee: 380_000, status: :active, type: :bank_transfer },
    { name: "한유찬", grade: "초1", fee: 200_000, status: :withdrawn, type: :bank_transfer },
    { name: "오세빈", grade: "초3", fee: 250_000, status: :active, type: :bank_transfer }
  ].freeze

  def initialize(tenant:)
    @tenant = tenant
  end

  def call
    Tenant.transaction do
      SAMPLES.each_with_index do |sample, index|
        student = @tenant.students.create!(
          name: sample[:name],
          grade: sample[:grade],
          monthly_fee: sample[:fee],
          payment_type: Student.payment_types[sample[:type]],
          status: Student.statuses[sample[:status]],
          memo: "연습 모드 샘플 데이터"
        )
        student.guardians.create!(
          name: "보호자 #{sample[:name][0]}",
          phone_number: format("010%08d", 1000_0000 + index * 11_111)
        )
      end
    end
  end
end
