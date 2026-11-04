require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Phase 7(랜딩·퍼블리싱)부터 시스템 테스트 도입 — 원장 핵심 플로우가 늘어날 때만 추가 권장(스킬 원칙)
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 800 ]
end
