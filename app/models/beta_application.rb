# 베타(파일럿) 신청 — PRD 13.6 (랜딩 전환 지점)
# Rule ID: TEN-002(주민번호 등 불필요 항목 수집 금지), TEN-003(연락처 암호화),
#          TEN-006 준용(IP·UA 등 부가 기록 없음 — 신청 처리에 필요한 최소 항목만 저장)
class BetaApplication < ApplicationRecord
  # 선택 옵션은 키 값 저장 + ko.yml(enums.beta_application.*) 라벨 매핑 — 문구는 ko.yml 관리(AGENTS.md)
  TITLE_OPTIONS = %w[principal teacher other].freeze
  ACADEMY_TYPE_OPTIONS = %w[academy study_room other].freeze
  STUDENT_COUNT_RANGES = %w[1_15 16_30 31_70 71_plus].freeze
  CONTACT_TYPES = %w[email phone].freeze

  EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\z/
  PHONE_REGEX = /\A01[016789]\d{7,8}\z/ # User.phone_number와 동일 규칙

  # 연락처 암호화(TEN-003) — deterministic으로 중복 신청 최소 식별(13.6) 조회 가능
  encrypts :contact_value, deterministic: true

  validates :name, presence: true, length: { maximum: 20 }
  validates :title, inclusion: { in: TITLE_OPTIONS }
  validates :contact_type, inclusion: { in: CONTACT_TYPES }
  validates :contact_value, presence: true, length: { maximum: 100 }
  validates :academy_type, inclusion: { in: ACADEMY_TYPE_OPTIONS }
  validates :student_count_range, inclusion: { in: STUDENT_COUNT_RANGES }, allow_blank: true
  validates :current_method, :pain_point, length: { maximum: 500 }
  validates :terms_agreed, acceptance: true # 필수 동의(마케팅 수신은 분리·선택 — 검증 없음)

  validate :contact_value_format

  # 중복 신청 최소 식별(13.6) — contact 기준. 감지 시에도 정상 완료 화면으로 처리(노출 금지)
  scope :with_contact, ->(contact_type, contact_value) {
    where(contact_type: contact_type, contact_value: contact_value)
  }

  before_validation :normalize_contact

  private

  def normalize_contact
    if contact_type == "phone"
      self.contact_value = contact_value.to_s.gsub(/[^0-9]/, "")
    else
      self.contact_value = contact_value.to_s.strip
    end
  end

  def contact_value_format
    return if contact_value.blank? # presence 검증이 담당

    format_valid = case contact_type
    when "email" then contact_value.match?(EMAIL_REGEX)
    when "phone" then contact_value.match?(PHONE_REGEX)
    end
    return if format_valid

    errors.add(:contact_value, contact_type == "phone" ? :invalid_phone : :invalid_email)
  end
end
