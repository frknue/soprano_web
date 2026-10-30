import WebKit

/// The Mini Player's and the media controls' page script, in the trusted
/// isolated world of every frame. It reads the elements and
/// `navigator.mediaSession` (the DOM objects are shared with the page's
/// world, so the page's metadata reads here) and never runs page code
/// except the page's own Media Session handlers through WebKit's
/// `callActionHandler`.
@MainActor
enum BrowserMediaScripts {
    /// Posts `mediaInfo {frame, playing, video, audible, media, gone,
    /// title, artist, album, artwork, state}` (debounced 250 ms, only on
    /// change) on media events, scroll and resize, and every second while
    /// something plays (Media Session metadata changes fire no event).
    /// Defines `__sopranoMediaControl(action)` (play, pause, nexttrack,
    /// previoustrack) and `__sopranoMiniPlayer(on)` (the fill style).
    static let reporter = BrowserPageScript(
        source: """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sopranoWeb;
          if (!handler || globalThis.__sopranoMediaControl) return;
          const frame = Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, '0')).join('');
          const post = (message) => { try { handler.postMessage(message); } catch (_) {} };
          const played = new WeakSet();
          let lastPlayed = null;
          let pausedByUs = [];
          let last = '';
          let timer = 0;
          let poll = 0;
          const elements = () => Array.from(document.querySelectorAll('video, audio'));
          const isPlaying = (element) => !element.paused && !element.ended;
          const visibleVideo = (video) => {
            if (!(video instanceof HTMLVideoElement) || !isPlaying(video) || video.readyState < 2 || !video.videoWidth) return false;
            const rect = video.getBoundingClientRect();
            if (rect.width < 160 || rect.height < 90) return false;
            const width = Math.min(rect.right, window.innerWidth) - Math.max(rect.left, 0);
            const height = Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0);
            if (width <= 0 || height <= 0 || width * height < rect.width * rect.height * 0.5) return false;
            const style = getComputedStyle(video);
            return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0;
          };
          const artwork = (list) => {
            if (!list || !list.length) return '';
            let best = null;
            let bestSize = -1;
            for (const image of list) {
              if (!image || !image.src) continue;
              let size = 0;
              for (const part of String(image.sizes || '').split(/\\s+/)) {
                const match = /^(\\d+)x(\\d+)$/i.exec(part);
                if (match) size = Math.max(size, Number(match[1]) * Number(match[2]));
              }
              if (size >= bestSize) { best = image; bestSize = size; }
            }
            return best ? String(best.src) : '';
          };
          const read = () => {
            let playing = false, video = false, audible = false, media = false;
            for (const element of elements()) {
              if (isPlaying(element)) {
                played.add(element);
                playing = true;
                if (!element.muted && element.volume > 0) audible = true;
                if (visibleVideo(element)) video = true;
              }
              if (played.has(element) && !element.ended && element.readyState > 0) media = true;
            }
            const session = navigator.mediaSession;
            const meta = session && session.metadata;
            return {
              playing, video, audible, media,
              title: meta ? String(meta.title || '') : '',
              artist: meta ? String(meta.artist || '') : '',
              album: meta ? String(meta.album || '') : '',
              artwork: meta ? artwork(meta.artwork) : '',
              state: session ? String(session.playbackState || 'none') : 'none',
            };
          };
          const report = () => {
            const value = read();
            const text = JSON.stringify(value);
            if (text !== last) {
              last = text;
              post(Object.assign({ type: 'mediaInfo', frame, gone: false }, value));
            }
            if (value.playing && !poll) {
              poll = setInterval(report, 1000);
            } else if (!value.playing && poll) {
              clearInterval(poll);
              poll = 0;
            }
          };
          const schedule = () => {
            clearTimeout(timer);
            timer = setTimeout(report, 250);
          };
          for (const name of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'loadedmetadata', 'resize']) {
            document.addEventListener(name, (event) => {
              if (name === 'play' && event.target instanceof HTMLMediaElement) lastPlayed = new WeakRef(event.target);
              schedule();
            }, true);
          }
          window.addEventListener('scroll', schedule, { capture: true, passive: true });
          window.addEventListener('resize', schedule, { passive: true });
          window.addEventListener('pagehide', () => {
            clearTimeout(timer);
            clearInterval(poll);
            poll = 0;
            last = '';
            post({ type: 'mediaInfo', frame, gone: true });
          });
          window.addEventListener('pageshow', (event) => { if (event.persisted) schedule(); });
          const callSession = (action) => {
            const session = navigator.mediaSession;
            if (!session || typeof session.callActionHandler !== 'function') return false;
            try {
              const result = session.callActionHandler({ action });
              if (result && typeof result.catch === 'function') result.catch(() => {});
              return true;
            } catch (_) {
              return false;
            }
          };
          Object.defineProperty(globalThis, '__sopranoMediaControl', {
            value: (action) => {
              let done = false;
              if (action === 'pause') {
                pausedByUs = [];
                for (const element of elements()) {
                  if (!isPlaying(element)) continue;
                  element.pause();
                  pausedByUs.push(new WeakRef(element));
                  done = true;
                }
                if (!done) done = callSession('pause');
              } else if (action === 'play') {
                let targets = pausedByUs.map((ref) => ref.deref()).filter((element) => element && element.isConnected);
                if (!targets.length) {
                  const recent = lastPlayed && lastPlayed.deref();
                  if (recent && recent.isConnected) targets = [recent];
                }
                pausedByUs = [];
                for (const element of targets) {
                  const result = element.play();
                  if (result && typeof result.catch === 'function') result.catch(() => {});
                  done = true;
                }
                if (!done) done = callSession('play');
              } else if (action === 'nexttrack' || action === 'previoustrack') {
                done = callSession(action);
              }
              schedule();
              return done;
            },
          });
          let sheet = null;
          let filled = null;
          const fillStyle = `
            html, body { overflow: hidden !important; }
            :has(video[data-soprano-mini-player]) {
              transform: none !important; filter: none !important; contain: none !important;
              will-change: auto !important; z-index: 2147483647 !important;
            }
            video[data-soprano-mini-player] {
              position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
              max-width: none !important; max-height: none !important; margin: 0 !important; padding: 0 !important;
              transform: none !important; z-index: 2147483647 !important; object-fit: contain !important;
              background: #000 !important; border: 0 !important; border-radius: 0 !important;
              visibility: visible !important; opacity: 1 !important;
            }`;
          Object.defineProperty(globalThis, '__sopranoMiniPlayer', {
            value: (on) => {
              if (sheet) {
                document.adoptedStyleSheets = document.adoptedStyleSheets.filter((item) => item !== sheet);
                sheet = null;
              }
              if (filled) {
                filled.removeAttribute('data-soprano-mini-player');
                filled = null;
              }
              if (!on) return false;
              const videos = Array.from(document.querySelectorAll('video')).filter(isPlaying);
              const area = (video) => { const rect = video.getBoundingClientRect(); return rect.width * rect.height; };
              const target = videos.filter(visibleVideo).sort((a, b) => area(b) - area(a))[0]
                || videos.sort((a, b) => area(b) - area(a))[0];
              if (!target) return false;
              target.setAttribute('data-soprano-mini-player', '');
              filled = target;
              try {
                sheet = new CSSStyleSheet();
                sheet.replaceSync(fillStyle);
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
              } catch (_) {
                sheet = null;
              }
              return true;
            },
          });
          globalThis.__sopranoMediaRead = read;
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', schedule, { once: true });
          } else {
            schedule();
          }
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        world: .isolated
    )

    /// Runs one control action in a frame's isolated world; the result is
    /// whether anything took it.
    static func controlSource(_ action: BrowserMediaAction) -> String {
        "globalThis.__sopranoMediaControl ? globalThis.__sopranoMediaControl('\(action.rawValue)') : false"
    }

    /// Turns the Mini Player's fill style on or off in the main frame.
    static func fillSource(_ on: Bool) -> String {
        "globalThis.__sopranoMiniPlayer ? globalThis.__sopranoMiniPlayer(\(on)) : false"
    }

    /// Whether the fill style is on (the harness and tests read it).
    static let fillStateSource = """
        (() => {
          const video = document.querySelector('video[data-soprano-mini-player]');
          return video ? Math.round(video.getBoundingClientRect().width) + 'x' + Math.round(video.getBoundingClientRect().height) : '';
        })()
        """
}
