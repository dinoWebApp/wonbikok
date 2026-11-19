# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# ---------------------------------------------------------------------------
# 운영 관리자 시드 (W4 A0 — 1인 운영, 관리자 계정 1개)
#
#   ADMIN_EMAIL / ADMIN_PASSWORD 환경변경로 계정을 지정한다(개발 기본값: 아래 fetch 기본값).
#   ADMIN_PASSWORD 미지정 시 랜덤 생성 → 콘솔에 1회 출력(안전 보관 필수).
#   TOTP: AdminUser.otp_secret 미설정 시 Admin::OtpService가 credentials
#   `admin: { otp_seed: ... }`에서 계정별 파생 — otp_seed 미설정 환경(개발)은
#   폴백 시크릿 + 경고 로그가 사용된다(운영 배포 전 credentials 설정 필수,
#   Admin::OtpService 코드 주석 참조).
#
#   개발 OTP 확인: bin/rails runner 'puts Admin::OtpService.current_code(AdminUser.first)'
# ---------------------------------------------------------------------------
admin = AdminUser.find_or_create_by!(email: ENV.fetch("ADMIN_EMAIL", "ops@wonbikok.local")) do |user|
  user.password = ENV.fetch("ADMIN_PASSWORD") { SecureRandom.hex(12) }
end
if admin.previously_new_record?
  Rails.logger.info("[Seeds] AdminUser created email=#{admin.email} " \
                    "otp_source=#{admin.otp_secret.present? ? "otp_secret" : "otp_seed/폴백"}")
end

# ---------------------------------------------------------------------------
# 영업 직원·오피서 시드 (F10 — role별 샘플 1계정씩, ENV 기반)
#
#   SALES_EMAIL / SALES_PASSWORD   — sales 역할(20%·12개월 캡)
#   OFFICER_EMAIL / OFFICER_PASSWORD — officer 역할(15%·무기한)
#   미지정 시 개발 기본값. 생성 시 첫 추천 코드 발급(7일 — ReferralCodeRotationJob이 주간 갱신).
# ---------------------------------------------------------------------------
[
  { env_prefix: "SALES", role: "sales", name: "영업 직원 샘플", title: "영업 이사",
    default_email: "sales@wonbikok.local" },
  { env_prefix: "OFFICER", role: "officer", name: "오피서 샘플", title: "CRO",
    default_email: "officer@wonbikok.local" }
].each do |config|
  rep = SalesRep.find_or_create_by!(email: ENV.fetch("#{config[:env_prefix]}_EMAIL",
                                                        config[:default_email])) do |record|
    record.name = config[:name]
    record.role = config[:role]
    record.title = config[:title]
    record.password = ENV.fetch("#{config[:env_prefix]}_PASSWORD") { SecureRandom.hex(12) }
  end
  Referral::CodeService.issue_for!(rep) if rep.active_referral_code.nil?
end
