module PhoneHelper
  # 010-****-5678 형태 마스킹 (TEN-003)
  def masked_phone(phone_number)
    digits = phone_number.to_s.gsub(/[^0-9]/, "")
    return "" if digits.blank?

    head = digits[0, 3]
    tail = digits[-4, 4]
    "#{head}-****-#{tail}"
  end
end
