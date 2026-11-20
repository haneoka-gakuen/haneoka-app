import { escape, icon, t } from "./app.js";

export function scrollableTabBar({ id, label, tabs, active }) {
  return `<div class="tab-scroll">
    <button class="icon-button tab-scroll__previous" type="button" aria-label="${escape(t("tabPrevious"))}" aria-disabled="true">${icon("chevron_right")}</button>
    <nav class="save-tabs" role="tablist" aria-label="${escape(label)}">
      ${tabs.map(([tab, key]) => `<button class="save-tab" type="button" role="tab" id="${id}-${tab}"
        aria-controls="${id}-panel" aria-selected="${tab === active}" tabindex="${tab === active ? 0 : -1}"
        data-tab="${tab}">${escape(t(key))}</button>`).join("")}
    </nav>
    <button class="icon-button tab-scroll__next" type="button" aria-label="${escape(t("tabNext"))}" aria-disabled="true">${icon("chevron_right")}</button>
  </div>`;
}

export function mountScrollableTabBar(wrapper, { scrollLeft, select }) {
  const strip = wrapper.querySelector("nav");
  const previous = wrapper.querySelector(".tab-scroll__previous");
  const next = wrapper.querySelector(".tab-scroll__next");
  const tabs = [...strip.querySelectorAll("[data-tab]")];
  const selected = strip.querySelector('[aria-selected="true"]');
  const edges = () => {
    previous.setAttribute("aria-disabled", String(strip.scrollLeft <= 1));
    next.setAttribute("aria-disabled", String(strip.scrollLeft >= strip.scrollWidth - strip.clientWidth - 1));
  };
  const resize = new ResizeObserver(measure);
  function measure() {
    wrapper.toggleAttribute("data-overflow", wrapper.clientWidth > 0 && strip.scrollWidth > wrapper.clientWidth + 1);
    edges();
  }
  const reveal = (tab) => {
    if (!tab || !wrapper.hasAttribute("data-overflow")) return;
    const bounds = strip.getBoundingClientRect(), button = tab.getBoundingClientRect();
    if (button.left < bounds.left) strip.scrollLeft += button.left - bounds.left;
    else if (button.right > bounds.right) strip.scrollLeft += button.right - bounds.right;
  };
  const scroll = (button, direction) => {
    if (button.getAttribute("aria-disabled") !== "true") strip.scrollBy({
      left: direction * strip.clientWidth * 0.8,
      behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth",
    });
  };
  previous.addEventListener("click", () => scroll(previous, -1));
  next.addEventListener("click", () => scroll(next, 1));
  strip.addEventListener("scroll", edges, { passive: true });
  strip.addEventListener("focusin", ({ target }) => reveal(target.closest("[data-tab]")));
  strip.addEventListener("click", ({ target }) => {
    const button = target.closest("[data-tab]");
    if (button) select(button.dataset.tab);
  });
  strip.addEventListener("keydown", (event) => {
    const current = tabs.indexOf(event.target.closest("[data-tab]"));
    if (current < 0) return;
    const index = {
      ArrowLeft: (current + tabs.length - 1) % tabs.length,
      ArrowRight: (current + 1) % tabs.length,
      Home: 0,
      End: tabs.length - 1,
    }[event.key];
    if (index === undefined) return;
    event.preventDefault();
    select(tabs[index].dataset.tab);
  });
  resize.observe(wrapper);
  tabs.forEach(tab => resize.observe(tab));
  measure();
  strip.scrollLeft = scrollLeft;
  if (scrollLeft === 0 && selected !== tabs[0]) reveal(selected);
  edges();
  return () => resize.disconnect();
}
