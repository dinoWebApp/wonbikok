require "application_system_test_case"

class LandingResponsiveTest < ApplicationSystemTestCase
  # 랜딩 반응형·렌더 스모크 (PRD 16장 반응형 — 모바일 360px 우선, 가로 스크롤 금지)
  # 범위: 렌더 + 상호작용(히어로 CTA 앵커·폼 입력·FAQ 아코디언). 폼 제출 플로우는
  # 통합 테스트(BetaApplicationsControllerTest)가 담당 — 중복 시나리오 방지

  MOBILE_WIDTH = 360
  MOBILE_HEIGHT = 740

  # headless Chrome(신모드)은 최소 윈도우 폭 500px 제약이 있어 window resize로는
  # 360px 뷰포트를 만들 수 없다 → CDP 디바이스 에뮬레이션으로 뷰포트를 강제한다.
  # 방문 후 적용해야 레이아웃·미디어쿼리가 360px 기준으로 재계산된다.
  def emulate_mobile_viewport
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: MOBILE_WIDTH, height: MOBILE_HEIGHT, deviceScaleFactor: 1, mobile: true)
  end

  test "360px 뷰포트에서 랜딩이 가로 스크롤 없이 렌더된다" do
    visit root_url
    emulate_mobile_viewport

    scroll_width = page.evaluate_script("document.documentElement.scrollWidth")
    assert scroll_width <= MOBILE_WIDTH,
           "360px에서 가로 스크롤 발생(scrollWidth=#{scroll_width}) — 랜딩 반응형 위반(PRD 16장)"
  end

  test "360px 뷰포트에서 CTA가 폼 섹션(#beta)으로 이동한다" do
    visit root_url
    emulate_mobile_viewport

    # 헤더 CTA + 히어로 CTA 모두 cta_hero 이벤트 지점(13.5)
    assert_selector "a[data-event='cta_hero']", count: 2
    within "header" do
      click_on I18n.t("landing.header.cta")
    end

    assert_current_path(/#beta\z/, url: true)
    assert_selector "form[data-event='form_start']"
  end

  test "360px 뷰포트에서 베타 폼 필드가 표시되고 입력 가능하다" do
    visit "#{root_url}#beta"
    emulate_mobile_viewport

    name_label = I18n.t("beta_applications.form.name")
    fill_in name_label, with: "김원장"

    assert_equal "김원장", page.find_field(name_label).value
    assert_selector "select[name='beta_application[title]']"
    assert_selector "input[name='beta_application[contact_value]']"
    assert_selector "input[name='beta_application[terms_agreed]']"
  end

  test "FAQ 아코디언이 클릭으로 열리고 닫힌다(details/summary)" do
    visit root_url
    emulate_mobile_viewport

    refute_selector "details[open]" # 초기 상태 — 전부 접힘

    page.first("details").find("summary").click
    assert_selector "details[open]", count: 1

    page.first("details[open]").find("summary").click
    refute_selector "details[open]"
  end
end
