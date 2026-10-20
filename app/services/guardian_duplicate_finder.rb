# 동일 보호자 전화번호(형제·자매) 및 유사 이름 중복 원생 탐지 서비스.
#
# 참고: Guardian.phone_number는 비결정 암호화(TEN-003)라 SQL 동등 비교가 불가해
# W1 스케일(원생 수십 명)에서는 Ruby 메모리 비교로 처리한다. 원생 수가 커지면
# 결정론적 해시 컬럼 도입을 검토한다(열린 이슈).
class GuardianDuplicateFinder
  def initialize(tenant)
    @tenant = tenant
  end

  # 같은 보호자 전화번호를 공유하는 원생 묶음(형제 그룹) — [[student, student], ...]
  def sibling_groups
    by_phone = Hash.new { |hash, key| hash[key] = [] }
    @tenant.students.includes(:guardians).find_each do |student|
      student.guardians.each { |guardian| by_phone[guardian.phone_number] << student }
    end
    by_phone.values.select { |students| students.map(&:id).uniq.size > 1 }
  end

  def sibling_student_ids
    sibling_groups.flatten.map(&:id).uniq
  end

  # 저장 전 확인 대상: 동일 보호자 전화 또는 유사 이름을 가진 기존 원생
  def conflicts_with(name:, phone_number:)
    normalized_phone = phone_number.to_s.gsub(/[^0-9]/, "")
    normalized_name = name.to_s.gsub(/\s+/, "")

    @tenant.students.includes(:guardians).select do |student|
      student.guardians.any? { |g| g.phone_number == normalized_phone } ||
        similar_name?(student.name, normalized_name)
    end
  end

  private

  def similar_name?(existing, candidate)
    return false if candidate.blank?

    normalized_existing = existing.to_s.gsub(/\s+/, "")
    normalized_existing == candidate ||
      normalized_existing.include?(candidate) || candidate.include?(normalized_existing)
  end
end
