// Demo player: turns each demo's audio fallback into a call view with perspectives.
// Without JavaScript the page keeps the plain audio players and transcripts.
(function () {
  "use strict";
  var data;
  try { data = JSON.parse(document.getElementById("demo-data").textContent); } catch (error) { return; }

  function element(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function clock(seconds) {
    var whole = Math.max(0, Math.floor(seconds));
    return Math.floor(whole / 60) + ":" + String(whole % 60).padStart(2, "0");
  }

  var AudioContextClass = window.AudioContext || window.webkitAudioContext;
  var context = null;

  // Every listener's track of a scene has the same length and plays in sync. Choosing a
  // listener crossfades to that track, so the conversation continues in another language.
  function syncedEngine(urls, duration, events) {
    var buffers = null, loading = null, sources = [], gains = [], selected = 0;
    var offset = 0, startedAt = 0, playing = false, frame = 0;
    function decode(url) {
      return fetch(url).then(function (response) {
        if (!response.ok) throw new Error("Demo audio is not available.");
        return response.arrayBuffer();
      }).then(function (data) {
        return new Promise(function (resolve, reject) { context.decodeAudioData(data, resolve, reject); });
      });
    }
    function now() { return playing ? Math.min(duration, offset + context.currentTime - startedAt) : offset; }
    function stopSources() {
      sources.forEach(function (source) { source.onended = null; try { source.stop(); } catch (error) { /* not started */ } });
      sources = []; gains = [];
    }
    function finish() { stopSources(); playing = false; offset = duration; cancelAnimationFrame(frame); events.time(duration); events.state(false); }
    function tick() {
      if (!playing) return;
      var at = now();
      events.time(at);
      if (at >= duration) finish(); else frame = requestAnimationFrame(tick);
    }
    function start() {
      stopSources();
      var at = context.currentTime + 0.03;
      buffers.forEach(function (buffer, index) {
        var gain = context.createGain();
        gain.gain.value = index === selected ? 1 : 0;
        gain.connect(context.destination);
        var source = context.createBufferSource();
        source.buffer = buffer; source.connect(gain);
        source.start(at, Math.min(offset, buffer.duration));
        sources.push(source); gains.push(gain);
      });
      sources[0].onended = function () { if (playing && now() >= duration - 0.1) finish(); };
      startedAt = at; playing = true; events.state(true); tick();
    }
    return {
      play: function () {
        if (!context) context = new AudioContextClass();
        if (context.state === "suspended") context.resume();
        if (offset >= duration - 0.05) offset = 0;
        if (buffers) { start(); return; }
        events.loading(true);
        if (!loading) loading = Promise.all(urls.map(decode)).then(function (decoded) { buffers = decoded; });
        loading.then(function () { events.loading(false); start(); }, function () { events.loading(false); events.failed(); });
      },
      pause: function () {
        if (!playing) return;
        offset = now(); playing = false; cancelAnimationFrame(frame); stopSources(); events.state(false);
      },
      seek: function (at) { offset = at; if (playing) start(); else events.time(at); },
      select: function (index) {
        selected = index;
        if (!playing) return;
        var at = context.currentTime;
        gains.forEach(function (gain, i) {
          gain.gain.cancelScheduledValues(at);
          gain.gain.setValueAtTime(gain.gain.value, at);
          gain.gain.linearRampToValueAtTime(i === index ? 1 : 0, at + 0.08);
        });
      },
      time: now,
      get playing() { return playing; }
    };
  }

  // Without Web Audio, one audio element loads the chosen track at the same position. The
  // engine keeps the position itself: while a track loads, the element reports 0.
  function elementEngine(urls, events) {
    var audio = new Audio(), selected = 0, position = 0, ready = false;
    audio.preload = "none";
    audio.src = urls[0];
    audio.addEventListener("loadedmetadata", function () { ready = true; audio.currentTime = position; });
    audio.addEventListener("play", function () { events.state(true); });
    audio.addEventListener("pause", function () { events.state(false); });
    audio.addEventListener("ended", function () { position = 0; events.state(false); });
    audio.addEventListener("timeupdate", function () { if (ready) { position = audio.currentTime; events.time(position); } });
    return {
      play: function () { audio.play(); },
      pause: function () { audio.pause(); },
      seek: function (at) { position = at; if (ready) audio.currentTime = at; events.time(at); },
      select: function (index) {
        if (index === selected) return;
        var wasPlaying = !audio.paused;
        selected = index; ready = false;
        audio.src = urls[index];
        audio.load();
        if (wasPlaying) audio.play();
      },
      time: function () { return position; },
      get playing() { return !audio.paused; }
    };
  }

  data.scenes.forEach(function (scene) {
    var host = document.querySelector('.demo[data-scene="' + scene.id + '"]');
    if (!host) return;
    var fallback = host.querySelector(".demo-fallback");
    var player = element("div", "demo-player");
    var current = scene.perspectives[0];

    // Call view: one tile per participant.
    var grid = element("div", "demo-call");
    grid.style.setProperty("--tiles", Object.keys(scene.speakers).length);
    var tiles = {};
    Object.keys(scene.speakers).forEach(function (key) {
      var speaker = scene.speakers[key];
      var tile = element("div", "demo-tile");
      var avatar = element("img", "demo-avatar");
      avatar.src = "assets/demos/" + speaker.portrait + ".webp";
      avatar.alt = ""; avatar.width = 96; avatar.height = 96; avatar.decoding = "async";
      tile.appendChild(avatar);
      tile.appendChild(element("span", "demo-name", speaker.name));
      tile.appendChild(element("span", "demo-place", speaker.city + " · " + speaker.languageName));
      var said = element("span", "demo-said");
      said.lang = speaker.language;
      tile.appendChild(said);
      tiles[key] = { tile: tile, said: said };
      grid.appendChild(tile);
    });

    // Perspective choice.
    var choices = element("div", "demo-choices");
    choices.setAttribute("role", "radiogroup");
    choices.setAttribute("aria-label", "Whose ears to listen with");
    var buttons = [];
    scene.perspectives.forEach(function (perspective) {
      var speaker = scene.speakers[perspective.listener];
      var label = speaker.name === "You" ? "Hear it as you" : "Hear it as " + speaker.name;
      var button = element("button", "demo-choice", label + " (" + speaker.languageName + ")");
      button.type = "button";
      button.setAttribute("role", "radio");
      button.addEventListener("click", function () { choose(perspective); });
      buttons.push({ button: button, perspective: perspective });
      choices.appendChild(button);
    });

    // Transport and caption.
    var transport = element("div", "demo-transport");
    var play = element("button", "button demo-play", "Play");
    play.type = "button";
    var progress = element("input", "demo-progress");
    progress.type = "range"; progress.min = 0; progress.max = scene.duration; progress.step = 0.1; progress.value = 0;
    progress.setAttribute("aria-label", "Position in the demo");
    var time = element("span", "demo-time", "0:00 / " + clock(scene.duration));
    transport.appendChild(play); transport.appendChild(progress); transport.appendChild(time);
    var caption = element("p", "demo-caption");
    var fish = element("img", "demo-fish");
    fish.src = "assets/demos/portrait-babelfin.webp"; fish.alt = ""; fish.width = 40; fish.height = 40;
    var heardText = element("span");
    heardText.setAttribute("aria-live", "polite");
    caption.appendChild(fish); caption.appendChild(heardText);

    player.appendChild(grid); player.appendChild(choices); player.appendChild(caption); player.appendChild(transport);
    fallback.hidden = true;
    host.insertBefore(player, fallback);

    var urls = scene.perspectives.map(function (perspective) { return perspective.audio; });
    var events = {
      state: function (playing) { play.textContent = playing ? "Pause" : "Play"; },
      loading: function (busy) { if (busy) play.textContent = "Loading…"; play.disabled = busy; },
      time: function (at) { render(at); },
      // The synced player could not load or decode the tracks: continue with one audio element.
      failed: function () {
        var at = engine.time();
        engine = elementEngine(urls, events);
        engine.seek(at);
        engine.select(scene.perspectives.indexOf(current));
        engine.play();
      }
    };
    var engine = AudioContextClass && window.fetch && window.Promise ? syncedEngine(urls, scene.duration, events) : elementEngine(urls, events);
    host.addEventListener("demo-pause", function () { engine.pause(); });

    function choose(perspective) {
      current = perspective;
      buttons.forEach(function (entry) { entry.button.setAttribute("aria-checked", String(entry.perspective === perspective)); });
      engine.select(scene.perspectives.indexOf(perspective));
      render(engine.time());
    }

    function render(at) {
      var listener = scene.speakers[current.listener];
      Object.keys(tiles).forEach(function (key) {
        var line = scene.lines.filter(function (item) { return item.speaker === key && at >= item.start && at <= item.end + 0.3; })[0];
        tiles[key].tile.classList.toggle("is-speaking", Boolean(line));
        tiles[key].tile.classList.toggle("is-listener", key === current.listener);
        tiles[key].said.textContent = line ? line.text : "";
      });
      var heard = "";
      current.translations.forEach(function (item) { if (item.t <= at && at - item.t < 7) heard = item.text; });
      scene.lines.forEach(function (item) {
        if (current.heardAsIs.indexOf(item.speaker) >= 0 && at >= item.start && at <= item.end + 0.5) heard = item.text;
      });
      heardText.textContent = heard ? (listener.name === "You" ? "You hear: " : listener.name + " hears: ") + heard : "";
      progress.value = at;
      time.textContent = clock(at) + " / " + clock(scene.duration);
    }

    play.addEventListener("click", function () { if (engine.playing) engine.pause(); else engine.play(); });
    progress.addEventListener("input", function () { engine.seek(Number(progress.value)); });
    choose(current);
  });

  // Scene tabs: one scenario at a time inside one panel, so the section stays compact.
  var articles = Array.prototype.slice.call(document.querySelectorAll(".demo[data-scene]"));
  if (articles.length < 2) return;
  var panel = element("div", "demo-panel");
  var tabs = element("div", "demo-tabs");
  tabs.setAttribute("role", "tablist");
  tabs.setAttribute("aria-label", "Demo scenarios");
  articles[0].parentNode.insertBefore(panel, articles[0]);
  panel.appendChild(tabs);
  var tabButtons = articles.map(function (article, index) {
    var title = article.querySelector("h3");
    var tab = element("button", "demo-tab", title ? title.textContent : "Demo " + (index + 1));
    tab.type = "button";
    tab.id = "demo-tab-" + article.dataset.scene;
    tab.setAttribute("role", "tab");
    tab.setAttribute("aria-controls", "demo-scene-" + article.dataset.scene);
    article.id = "demo-scene-" + article.dataset.scene;
    article.setAttribute("role", "tabpanel");
    article.setAttribute("aria-labelledby", tab.id);
    tab.addEventListener("click", function () { select(index); });
    tab.addEventListener("keydown", function (event) {
      var step = 0;
      if (event.key === "ArrowRight") step = 1;
      else if (event.key === "ArrowLeft") step = -1;
      else return;
      event.preventDefault();
      var next = (index + step + articles.length) % articles.length;
      select(next); tabButtons[next].focus();
    });
    tabs.appendChild(tab);
    panel.appendChild(article);
    return tab;
  });
  function select(selected) {
    articles.forEach(function (article, index) {
      var active = index === selected;
      article.hidden = !active;
      tabButtons[index].setAttribute("aria-selected", String(active));
      tabButtons[index].tabIndex = active ? 0 : -1;
      // A hidden scenario stops playing.
      if (!active) article.dispatchEvent(new Event("demo-pause"));
    });
  }
  select(0);
})();
