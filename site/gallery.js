// Screenshot gallery: one screenshot at a time, chosen with tabs, so the section keeps one height.
// Without JavaScript the page shows every screenshot in sequence.
(function () {
  "use strict";
  var gallery = document.querySelector(".gallery");
  if (!gallery) return;
  var items = Array.prototype.slice.call(gallery.querySelectorAll(".gallery-item"));
  if (items.length < 2) return;

  var tabs = document.createElement("div");
  tabs.className = "gallery-tabs";
  tabs.setAttribute("role", "tablist");
  tabs.setAttribute("aria-label", "Screenshots");
  gallery.insertBefore(tabs, items[0]);

  var buttons = items.map(function (item, index) {
    var tab = document.createElement("button");
    tab.type = "button";
    tab.className = "gallery-tab";
    tab.textContent = item.dataset.label;
    tab.id = "gallery-tab-" + item.dataset.shot;
    tab.setAttribute("role", "tab");
    tab.setAttribute("aria-controls", "gallery-shot-" + item.dataset.shot);
    item.id = "gallery-shot-" + item.dataset.shot;
    item.setAttribute("role", "tabpanel");
    item.setAttribute("aria-labelledby", tab.id);
    tab.addEventListener("click", function () { select(index); });
    tab.addEventListener("keydown", function (event) {
      var step = 0;
      if (event.key === "ArrowRight") step = 1;
      else if (event.key === "ArrowLeft") step = -1;
      else return;
      event.preventDefault();
      var next = (index + step + items.length) % items.length;
      select(next); buttons[next].focus();
    });
    tabs.appendChild(tab);
    return tab;
  });

  function select(selected) {
    items.forEach(function (item, index) {
      var active = index === selected;
      item.hidden = !active;
      buttons[index].setAttribute("aria-selected", String(active));
      buttons[index].tabIndex = active ? 0 : -1;
    });
  }
  gallery.classList.add("is-ready");
  select(0);
})();
